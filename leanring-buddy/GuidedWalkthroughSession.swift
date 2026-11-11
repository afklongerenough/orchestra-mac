//
//  GuidedWalkthroughSession.swift
//  leanring-buddy
//
//  "Show me how": teaches a task one step at a time while the user does it
//  themselves. Each step: look at the screen → the model picks the single
//  next step → the blue cursor flies there with a short instruction, which
//  is also spoken → wait until the user clicks or types (and pauses) →
//  look again. Orchestra never clicks anything in this mode.
//

import AppKit
import Foundation

@MainActor
final class GuidedWalkthroughSession {
    private let goal: String
    private let geminiAPI: GeminiAPI
    /// Says one instruction out loud (TTS, or the live voice in Live mode).
    private let speakInstruction: (String) async -> Void
    /// Points the blue cursor (AppKit global point, display frame, bubble text).
    private let showPointer: (CGPoint, CGRect, String) -> Void
    private let maximumStepCount = 20
    /// How long to wait for the user to act on a step before ending.
    private let userActionTimeoutSeconds: TimeInterval = 150
    /// After the last click/key, this much quiet means "done with this step".
    private let userQuietSecondsAfterAction: TimeInterval = 1.6
    private var completedStepLog: [String] = []
    private var lastUserInputDate = Date.distantPast
    private var userInputMonitors: [Any] = []

    init(goal: String,
         geminiAPI: GeminiAPI,
         speakInstruction: @escaping (String) async -> Void,
         showPointer: @escaping (CGPoint, CGRect, String) -> Void) {
        self.goal = goal
        self.geminiAPI = geminiAPI
        self.speakInstruction = speakInstruction
        self.showPointer = showPointer
    }

    func run() async -> ScreenTakeoverSession.Outcome {
        startWatchingUserInput()
        defer { stopWatchingUserInput() }

        for stepNumber in 1...maximumStepCount {
            if Task.isCancelled { return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "okay, stopped the walkthrough.") }

            let screenCaptures: [CompanionScreenCapture]
            do {
                screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(announceCapture: stepNumber == 1)
            } catch {
                return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "i couldn't see your screen, so i stopped.")
            }
            let labeledImages = screenCaptures.map { screenCapture in
                (data: screenCapture.imageData, label: screenCapture.label + " (coordinates: 0-1000 grid over this image)")
            }
            let stepPrompt = """
            what the user wants to learn: \(goal)
            step \(stepNumber) of at most \(maximumStepCount).
            steps they've already done:
            \(completedStepLog.isEmpty ? "(none yet)" : completedStepLog.joined(separator: "\n"))
            look at the screen now. if the last step didn't work (the screen didn't change as expected), give a corrected step.
            """

            var walkthroughReply = ""
            for attemptNumber in 1...2 {
                do {
                    let (replyText, _) = try await geminiAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: Self.walkthroughSystemPrompt,
                        userPrompt: attemptNumber == 1 ? stepPrompt : stepPrompt + "\n\nyour last reply had no [STEP: ...], [DONE: ...] or [ASK: ...] tag. reply again with exactly one tag.",
                        openCodeModelOverride: ScreenTakeoverSession.takeoverOpenCodeModel,
                        onTextChunk: { _ in }
                    )
                    walkthroughReply = replyText
                } catch is CancellationError {
                    return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "okay, stopped the walkthrough.")
                } catch {
                    OrchestraLog.write("🧭 Walkthrough step \(stepNumber): model error \(error.localizedDescription)")
                    return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "i had to stop, because \(error.localizedDescription).")
                }
                OrchestraLog.write("🧭 Walkthrough step \(stepNumber): \(walkthroughReply.prefix(300).replacingOccurrences(of: "\n", with: " "))")
                if Self.containsAnyTag(walkthroughReply) { break }
            }
            if Task.isCancelled { return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "okay, stopped the walkthrough.") }

            if let doneSummary = CompanionManager.extractTagContent(named: "DONE", from: walkthroughReply).tagContent {
                return ScreenTakeoverSession.Outcome(finished: true, spokenSummary: doneSummary)
            }
            if let question = CompanionManager.extractTagContent(named: "ASK", from: walkthroughReply).tagContent {
                return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: question)
            }
            guard let stepText = CompanionManager.extractTagContent(named: "STEP", from: walkthroughReply).tagContent else {
                return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "i lost track of the next step. ask me again and i'll start over from where you are.")
            }

            // "x,y | instruction" or "none | instruction" (keyboard-only steps).
            let stepParts = stepText.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let instructionText = stepParts.count == 2 ? stepParts[1] : stepText
            if stepParts.count == 2,
               let parsedPointArgument = ScreenTakeoverSession.parsePointArgument(stepParts[0]),
               let targetScreenCapture = ScreenTakeoverSession.screenCapture(number: parsedPointArgument.1, in: screenCaptures) {
                let appKitPoint = ScreenControl.appKitGlobalPoint(fromNormalizedPoint: parsedPointArgument.0, in: targetScreenCapture)
                showPointer(appKitPoint, targetScreenCapture.displayFrame, instructionText)
            }

            let stepShownDate = Date()
            await speakInstruction(instructionText)
            completedStepLog.append("- step \(stepNumber): \(instructionText)")

            switch await waitForUserToAct(after: stepShownDate) {
            case .acted:
                // Let the app react before looking again.
                try? await Task.sleep(nanoseconds: 700_000_000)
            case .timedOut:
                return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "i'll pause the walkthrough here. ask me again whenever you want to keep going.")
            case .cancelled:
                return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "okay, stopped the walkthrough.")
            }
        }
        return ScreenTakeoverSession.Outcome(finished: false, spokenSummary: "that was a long one, so i stopped the walkthrough. ask me to continue if you need more.")
    }

    // MARK: - Waiting for the user

    private enum UserActionResult {
        case acted
        case timedOut
        case cancelled
    }

    /// Done when the user clicked or typed after the step was shown and then
    /// paused briefly (so a whole word typed counts as one step).
    private func waitForUserToAct(after stepShownDate: Date) async -> UserActionResult {
        while true {
            if Task.isCancelled { return .cancelled }
            let now = Date()
            if lastUserInputDate > stepShownDate && now.timeIntervalSince(lastUserInputDate) >= userQuietSecondsAfterAction {
                return .acted
            }
            if now.timeIntervalSince(stepShownDate) > userActionTimeoutSeconds {
                return .timedOut
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func startWatchingUserInput() {
        // Global monitors only observe (they can't change or block input).
        let watchedEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: watchedEvents, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.lastUserInputDate = Date() }
        }) {
            userInputMonitors.append(globalMonitor)
        }
    }

    private func stopWatchingUserInput() {
        for monitor in userInputMonitors {
            NSEvent.removeMonitor(monitor)
        }
        userInputMonitors.removeAll()
    }

    // MARK: - Prompt

    private static func containsAnyTag(_ replyText: String) -> Bool {
        ["[STEP:", "[DONE:", "[ASK:"].contains { replyText.contains($0) }
    }

    private static let walkthroughSystemPrompt = """
    you are teaching the user how to do something on their mac, one step at a time. they do every step themselves; you never click. each turn you see a fresh screenshot and give only the single next step.

    reply with exactly one tag:
    [STEP: x,y | instruction]    point at the thing to use (x,y on a 0-1000 grid over the screenshot: 0,0 top-left, 1000,1000 bottom-right; add :screen2 after y for another monitor) and say what to do with it
    [STEP: none | instruction]   for a step with nothing to point at (e.g. "press command s")
    [DONE: short friendly wrap-up]   when the goal is reached
    [ASK: one question]          only if you can't tell what they want

    rules:
    - one action per step, 4 to 14 words, plain speech: "click the blue share button", "type your email here". say keyboard shortcuts in words ("command c").
    - read the screen carefully and aim for the center of the element.
    - if the screen shows they already did a step, move on; if something went wrong, help them fix it.
    - for anything that can't be undone (send, buy, delete), say what it does before they click.
    - lowercase, warm, no lists.
    """
}

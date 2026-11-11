//
//  ScreenTakeoverSession.swift
//  leanring-buddy
//
//  "Take over my screen and do it": a short see → decide → act loop.
//  Each step captures the screens, asks Gemini (the smarter model) for the
//  next one to three actions, runs them with ScreenControl, and repeats
//  until the model says DONE, asks a question, or the step limit is hit.
//  Holding the hotkey again cancels it (CompanionManager cancels the task).
//
//  Rebuilt from scratch after studying HeyClicky's start/end_screen_takeover.
//

import AppKit
import Foundation

@MainActor
final class ScreenTakeoverSession {
    struct Outcome {
        let finished: Bool
        let spokenSummary: String
    }

    private let goal: String
    private let geminiAPI: GeminiAPI
    private let macActionRunner: MacActionRunner
    /// Shows the blue cursor where we're about to click (AppKit global point + display frame).
    private let showCursorAt: (CGPoint, CGRect) -> Void
    private let maximumStepCount = 15
    private var actionLog: [String] = []
    /// With the OpenCode brain, takeover uses a model that's better at finding
    /// things on screen than the everyday chat model (change with this default).
    static let takeoverModelDefaultsKey = "takeoverOpenCodeModel"
    static var takeoverOpenCodeModel: String {
        let savedModel = UserDefaults.standard.string(forKey: takeoverModelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (savedModel?.isEmpty == false) ? savedModel! : "gemini-4-argon"
    }

    init(goal: String,
         geminiAPI: GeminiAPI,
         macActionRunner: MacActionRunner,
         showCursorAt: @escaping (CGPoint, CGRect) -> Void) {
        self.goal = goal
        self.geminiAPI = geminiAPI
        self.macActionRunner = macActionRunner
        self.showCursorAt = showCursorAt
    }

    func run() async -> Outcome {
        for stepNumber in 1...maximumStepCount {
            if Task.isCancelled {
                return Outcome(finished: false, spokenSummary: "okay, stopped.")
            }

            let screenCaptures: [CompanionScreenCapture]
            do {
                screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            } catch {
                return Outcome(finished: false, spokenSummary: "i couldn't see your screen, so i stopped.")
            }

            let labeledImages = screenCaptures.map { screenCapture in
                (data: screenCapture.imageData,
                 label: screenCapture.label + " (coordinates: 0-1000 grid over this image)")
            }

            let stepPrompt = """
            goal: \(goal)
            step \(stepNumber) of at most \(maximumStepCount).
            actions done so far:
            \(actionLog.isEmpty ? "(none yet)" : actionLog.joined(separator: "\n"))
            look at the screen now and give the next actions.
            """

            var commandTexts: [String] = []
            // A reply without [DO: …] tags gets one retry with a reminder
            // before giving up, instead of stopping right away.
            for attemptNumber in 1...2 {
                let attemptPrompt = attemptNumber == 1
                    ? stepPrompt
                    : stepPrompt + "\n\nyour last reply had no [DO: ...] tags, so nothing happened. reply again: one short note, then the actions as [DO: ...] tags. if you truly can't tell what to do, use [DO: ask ...] with a specific question."
                let modelReply: String
                do {
                    let (replyText, _) = try await geminiAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: Self.takeoverSystemPrompt,
                        userPrompt: attemptPrompt,
                        openCodeModelOverride: Self.takeoverOpenCodeModel,
                        onTextChunk: { _ in }
                    )
                    modelReply = replyText
                } catch {
                    OrchestraLog.write("🖱️ Takeover step \(stepNumber): model error \(error.localizedDescription)")
                    return Outcome(finished: false, spokenSummary: "i stopped, because \(error.localizedDescription).")
                }
                if Task.isCancelled {
                    return Outcome(finished: false, spokenSummary: "okay, stopped.")
                }
                OrchestraLog.write("🖱️ Takeover step \(stepNumber) (try \(attemptNumber)): \(modelReply.prefix(400).replacingOccurrences(of: "\n", with: " "))")
                commandTexts = Self.extractCommands(from: modelReply)
                if !commandTexts.isEmpty { break }
            }
            if commandTexts.isEmpty {
                return Outcome(finished: false, spokenSummary: "i couldn't work out the next step on screen. can you tell me exactly what to click or what text you mean?")
            }

            for commandText in commandTexts {
                // Holding the hotkey cancels us; stop before every single action.
                if Task.isCancelled {
                    return Outcome(finished: false, spokenSummary: "okay, stopped.")
                }
                let commandName = commandText.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
                let commandArgument = commandText.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

                switch commandName {
                case "done":
                    return Outcome(finished: true, spokenSummary: commandArgument.isEmpty ? "done." : commandArgument)
                case "ask", "stop":
                    return Outcome(finished: false, spokenSummary: commandArgument.isEmpty ? "i need you for the next bit." : commandArgument)
                case "drag":
                    // "drag x1,y1 to x2,y2" (grid coordinates) — mainly for selecting text.
                    let dragEndpointTexts = commandArgument.components(separatedBy: " to ")
                    guard dragEndpointTexts.count == 2,
                          let dragStart = Self.parsePointArgument(dragEndpointTexts[0]),
                          let dragEnd = Self.parsePointArgument(dragEndpointTexts[1]),
                          let dragScreenCapture = Self.screenCapture(number: dragStart.1 ?? dragEnd.1, in: screenCaptures) else {
                        actionLog.append("- \(commandText) (skipped: write it as drag x1,y1 to x2,y2)")
                        continue
                    }
                    let dragStartAppKitPoint = ScreenControl.appKitGlobalPoint(fromNormalizedPoint: dragStart.0, in: dragScreenCapture)
                    let dragEndAppKitPoint = ScreenControl.appKitGlobalPoint(fromNormalizedPoint: dragEnd.0, in: dragScreenCapture)
                    // Never drop something onto a Delete/Trash-style target.
                    if let irreversibleLabel = ScreenControl.irreversibleControlLabel(atAppKitGlobalPoint: dragEndAppKitPoint) {
                        return Outcome(finished: false, spokenSummary: "i'm leaving that drag to you, since it ends on \(irreversibleLabel).")
                    }
                    showCursorAt(dragEndAppKitPoint, dragScreenCapture.displayFrame)
                    ScreenControl.drag(fromAppKitGlobalPoint: dragStartAppKitPoint, toAppKitGlobalPoint: dragEndAppKitPoint)
                    actionLog.append("- \(commandText)")
                case "click", "double_click", "triple_click", "right_click":
                    guard let parsedPointArgument = Self.parsePointArgument(commandArgument) else {
                        actionLog.append("- \(commandText) (skipped: couldn't read coordinates)")
                        continue
                    }
                    let normalizedPoint = parsedPointArgument.0
                    let targetScreenCapture = Self.screenCapture(number: parsedPointArgument.1, in: screenCaptures)
                    guard let targetScreenCapture else { continue }
                    let appKitPoint = ScreenControl.appKitGlobalPoint(fromNormalizedPoint: normalizedPoint, in: targetScreenCapture)
                    showCursorAt(appKitPoint, targetScreenCapture.displayFrame)
                    // Enforced in code: never press Send/Buy/Delete-style buttons ourselves.
                    if let irreversibleLabel = ScreenControl.irreversibleControlLabel(atAppKitGlobalPoint: appKitPoint) {
                        return Outcome(finished: false,
                                       spokenSummary: "it's all set up. i'm leaving the next click to you, since it's \(irreversibleLabel).")
                    }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if Task.isCancelled {
                        return Outcome(finished: false, spokenSummary: "okay, stopped.")
                    }
                    let clickKind: ScreenControl.MouseClickKind
                    switch commandName {
                    case "double_click": clickKind = .double
                    case "triple_click": clickKind = .triple
                    case "right_click": clickKind = .right
                    default: clickKind = .left
                    }
                    ScreenControl.click(atAppKitGlobalPoint: appKitPoint, kind: clickKind)
                    actionLog.append("- \(commandText)")
                case "wait":
                    let waitSeconds = min(10, max(1, Double(commandArgument.filter { $0.isNumber || $0 == "." }) ?? 2))
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                    actionLog.append("- \(commandText)")
                case "key", "press":
                    if let blockReason = MacActionRunner.keyPressBlockReason(commandArgument) {
                        return Outcome(finished: false, spokenSummary: "it's ready. \(blockReason).")
                    }
                    let results = await macActionRunner.runActions([commandText])
                    let resultNote = results.first.map { $0.succeeded ? "" : " (failed: \($0.detail ?? "error"))" } ?? ""
                    actionLog.append("- \(commandText)\(resultNote)")
                default:
                    // type / scroll / open_app / open_url / spotify / volume
                    let results = await macActionRunner.runActions([commandText])
                    let resultNote = results.first.map { $0.succeeded ? "" : " (failed: \($0.detail ?? "error"))" } ?? ""
                    actionLog.append("- \(commandText)\(resultNote)")
                }
                // Give the UI a moment to react before the next action.
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            // Let the screen settle before looking again.
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return Outcome(finished: false, spokenSummary: "that took more steps than i allow, so i stopped. want me to keep going?")
    }

    // MARK: - Parsing

    /// Commands come as [DO: click 120,340] tags, in order.
    static func extractCommands(from replyText: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[DO:\s*([^\]]+?)\s*\]"#) else { return [] }
        let fullRange = NSRange(replyText.startIndex..., in: replyText)
        return regex.matches(in: replyText, range: fullRange).compactMap { match in
            Range(match.range(at: 1), in: replyText).map { String(replyText[$0]) }
        }
    }

    /// "120,340" or "120, 340:screen2" → (point, screen number or nil)
    static func parsePointArgument(_ argumentText: String) -> (CGPoint, Int?)? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*,\s*(\d+)(?:\s*:\s*screen(\d+))?"#),
              let match = regex.firstMatch(in: argumentText, range: NSRange(argumentText.startIndex..., in: argumentText)),
              let xRange = Range(match.range(at: 1), in: argumentText),
              let yRange = Range(match.range(at: 2), in: argumentText),
              let xValue = Double(argumentText[xRange]),
              let yValue = Double(argumentText[yRange]) else {
            return nil
        }
        var screenNumber: Int?
        if let screenRange = Range(match.range(at: 3), in: argumentText) {
            screenNumber = Int(argumentText[screenRange])
        }
        return (CGPoint(x: xValue, y: yValue), screenNumber)
    }

    /// Screen 1 is the cursor screen (captures are sorted that way).
    static func screenCapture(number screenNumber: Int?, in screenCaptures: [CompanionScreenCapture]) -> CompanionScreenCapture? {
        if let screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
    }

    // MARK: - Prompt

    private static let takeoverSystemPrompt = """
    you are controlling the user's mac to finish a goal for them. each turn you see fresh screenshots and give the next 1 to 3 actions.

    coordinates: every x,y is on a 0-1000 grid laid over the screenshot — 0,0 is the top-left corner, 1000,1000 the bottom-right, 500,500 the center — no matter the image size. x goes left→right, y goes top→bottom.

    reply with a very short note, then the actions as tags, in order:
    [DO: click x,y]            left click (add :screen2 for another monitor, e.g. click 400,300:screen2)
    [DO: double_click x,y]     selects a word
    [DO: triple_click x,y]     selects a whole line or paragraph
    [DO: drag x1,y1 to x2,y2]  press, move, release: select a span of text (start of text to end of text)
    [DO: right_click x,y]
    [DO: type some text]       types into the focused field (click the field first)
    [DO: key cmd+l]            key combo: cmd, shift, opt, ctrl + a letter, or return, tab, esc, space, delete, up, down, left, right, pageup, pagedown. cmd+c copies the selection, cmd+v pastes, cmd+a selects all.
    [DO: scroll 5]             scroll down 5 lines (negative scrolls up; if it went the wrong way, use the opposite sign)
    [DO: wait 2]               wait seconds for something to load
    [DO: open_app Notes]       open an app by name
    [DO: open_url https://...] open a link
    [DO: done short spoken summary of what you did]
    [DO: ask the one question you need the user to answer]

    rules:
    - aim for the center of the element. read the text on the screen carefully before choosing a point.
    - to copy something: select it (double_click a word, triple_click a line, or drag across it), then key cmd+c. to write something: click the text field first, then type.
    - prefer keyboard shortcuts and open_url when they are more reliable than clicking.
    - after an action that changes the screen (click, open, return), stop giving actions for this turn so you can look again. typing then return is fine in search bars and address bars.
    - never do the final irreversible step yourself: do not press send, post, submit payment, buy, delete, or confirm deletion. instead stop with [DO: ask ...] saying it's ready for the user to press.
    - never type passwords, codes, or card numbers. ask the user to type them.
    - if the goal is already done, reply [DO: done ...]. if you are stuck after trying twice, [DO: ask ...].
    - the summary and questions are spoken aloud: lowercase, short, friendly.
    """
}

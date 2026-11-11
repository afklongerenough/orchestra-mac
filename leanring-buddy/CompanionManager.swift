//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Gemini answers every voice request, using the user's own key from the
    /// Keychain (no proxy worker needed for a personal build).
    private lazy var geminiAPI: GeminiAPI = {
        return GeminiAPI(model: selectedModel)
    }()

    /// Replies are spoken with Gemini's natural voice (Mac voice as fallback).
    private lazy var speechOutputClient: SpeechOutputClient = {
        let newSpeechOutputClient = SpeechOutputClient()
        self.speechFallbackCancellable = newSpeechOutputClient.$lastReplyUsedMacVoiceFallback
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usedFallback in self?.isUsingMacVoiceFallback = usedFallback }
        return newSpeechOutputClient
    }()
    /// Shown in the panel so the user can tell when the natural voice failed.
    @Published private(set) var isUsingMacVoiceFallback = false
    private var speechFallbackCancellable: AnyCancellable?

    /// Background jobs handed to Hermes (see OrchestraJobManager).
    let orchestraJobManager = OrchestraJobManager()

    /// Runs [ACTION: ...] tags on this Mac (see MacActionRunner).
    private let macActionRunner = MacActionRunner()

    /// Briefly true right after a screenshot, so the overlay can flash.
    @Published private(set) var isShowingScreenCaptureFlash = false
    private var screenCaptureObserver: NSObjectProtocol?
    private var screenCaptureFlashGeneration = 0

    private func observeScreenCapturesForFlash() {
        screenCaptureObserver = NotificationCenter.default.addObserver(forName: .orchestraScreenCaptured, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Overlapping captures: only the latest flash turns it off.
                self.screenCaptureFlashGeneration += 1
                let thisFlashGeneration = self.screenCaptureFlashGeneration
                self.isShowingScreenCaptureFlash = true
                try? await Task.sleep(nanoseconds: 220_000_000)
                if self.screenCaptureFlashGeneration == thisFlashGeneration {
                    self.isShowingScreenCaptureFlash = false
                }
            }
        }
    }

    /// Shapes drawn on the overlay by [DRAW: ...] tags (cleared after a few seconds).
    @Published private(set) var screenAnnotations: [ScreenAnnotation] = []
    private var screenAnnotationClearTask: Task<Void, Never>?
    /// Jobs currently working, for the status pill.
    @Published private(set) var runningJobCount: Int = 0
    private var runningJobCountCancellable: AnyCancellable?

    private func showScreenAnnotations(_ newScreenAnnotations: [ScreenAnnotation]) {
        screenAnnotationClearTask?.cancel()
        screenAnnotations = newScreenAnnotations
        screenAnnotationClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled else { return }
            self?.screenAnnotations = []
        }
    }

    /// Shares the action runner with background Mac jobs. Called from start().
    private func connectJobManagerToMacActions() {
        orchestraJobManager.macActionRunner = macActionRunner
        runningJobCountCancellable = orchestraJobManager.$jobs
            .map { jobs in jobs.filter { $0.state == .running || $0.state == .sending }.count }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runningJobCount in self?.runningJobCount = runningJobCount }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Gemini model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedGeminiModel") ?? GeminiAPI.defaultModel

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedGeminiModel")
        geminiAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether a Gemini API key is saved in the Keychain. Replaces the old
    /// "drop your email" onboarding step.
    @Published var hasGeminiAPIKey: Bool = GeminiAPI.hasAPIKey

    func saveGeminiAPIKey(_ apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else { return }
        KeychainStore.write(trimmedAPIKey, for: .geminiAPIKey)
        hasGeminiAPIKey = GeminiAPI.hasAPIKey
    }

    func clearGeminiAPIKey() {
        KeychainStore.delete(.geminiAPIKey)
        hasGeminiAPIKey = false
    }

    // MARK: - Hermes bridge settings

    @Published var hermesBridgeURLText: String = UserDefaults.standard.string(forKey: HermesBridgeClient.bridgeURLDefaultsKey) ?? HermesBridgeClient.defaultBridgeURLText
    @Published var hasHermesBridgeToken: Bool = KeychainStore.read(.hermesBridgeToken) != nil

    func saveHermesBridgeSettings(bridgeURLText: String, bridgeToken: String) {
        let trimmedBridgeURLText = bridgeURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedBridgeURLText, forKey: HermesBridgeClient.bridgeURLDefaultsKey)
        hermesBridgeURLText = trimmedBridgeURLText
        if !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainStore.write(bridgeToken, for: .hermesBridgeToken)
        }
        hasHermesBridgeToken = KeychainStore.read(.hermesBridgeToken) != nil
        orchestraJobManager.resetHermesConnection()
    }

    func start() {
        refreshAllPermissions()
        OrchestraUpdater.shared.startPeriodicChecks()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        orchestraJobManager.onJobFinishedAnnouncement = { [weak self] announcement in
            self?.queueJobAnnouncement(announcement)
        }
        connectJobManagerToMacActions()
        observeScreenCapturesForFlash()
        orchestraJobManager.resumeUnfinishedJobs()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = geminiAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    // MARK: - Job announcements

    /// Announcements wait in line so two jobs finishing together are both said.
    private var jobAnnouncementChainTask: Task<Void, Never>?

    /// Says a finished job out loud — never dropped. In Live mode the live
    /// voice says it (when nobody is talking); otherwise it waits until
    /// Orchestra is idle and not speaking, then uses the normal voice.
    private func queueJobAnnouncement(_ announcement: String) {
        let previousAnnouncementTask = jobAnnouncementChainTask
        jobAnnouncementChainTask = Task { [weak self] in
            await previousAnnouncementTask?.value
            guard let self else { return }
            OrchestraLog.write("📣 Job announcement: \(announcement.prefix(120))")
            let liveNoteText = "(note from orchestra, not the user) a background job just finished: \(announcement) — tell the user in one or two short sentences."
            let waitStartDate = Date()
            while Date().timeIntervalSince(waitStartDate) < 600 {
                if self.isLiveSessionActive, let liveSession = self.geminiLiveSession {
                    // Up to a minute for a pause in the conversation.
                    if await liveSession.sendTextTurn(liveNoteText, maximumWaitSeconds: 60) {
                        // Let the live voice start answering before the next note goes in.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        return
                    }
                } else {
                    // (.responding can linger after speech ends, so only listening/thinking/speaking count as busy.)
                    let isBusy = self.voiceState == .listening || self.voiceState == .processing
                        || self.speechOutputClient.isPlaying || self.buddyDictationManager.isDictationInProgress
                    if !isBusy {
                        try? await self.speechOutputClient.speakText(announcement)
                        // speakText returns once playback starts; finish (at most 2 minutes) before the next one.
                        let playbackStartDate = Date()
                        while self.speechOutputClient.isPlaying && Date().timeIntervalSince(playbackStartDate) < 120 {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            OrchestraLog.write("📣 Gave up announcing after 10 minutes (the notification is still there)")
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Live mode: one tap starts a two-way conversation, the next ends it.
            if isLiveModeEnabled {
                // During a live takeover, a tap stops the takeover but keeps the conversation.
                // (A second tap, once a stop was asked for, ends the conversation as usual.)
                if isScreenTakeoverRunning && isLiveSessionActive && stoppedTakeoverStartNumber != takeoverStartNumber {
                    stopRunningScreenTakeover()
                    return
                }
                currentScreenTakeoverTask?.cancel()
                if !isClickyCursorEnabled && !isOverlayVisible {
                    overlayWindowManager.hasShownOverlayBefore = true
                    overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    isOverlayVisible = true
                }
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                toggleLiveSession()
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response, screen takeover and TTS from a previous utterance
            currentResponseTask?.cancel()
            currentScreenTakeoverTask?.cancel()
            speechOutputClient.stopPlayback()
            screenAnnotationClearTask?.cancel()
            screenAnnotations = []
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // In live mode the hotkey is a toggle, so releasing it does nothing.
            if isLiveModeEnabled { return }
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    /// The name typed under Connections ("Your name"), so Orchestra can use it.
    static let userDisplayNameDefaultsKey = "userDisplayName"

    private static var userNamePromptLine: String {
        let savedName = (UserDefaults.standard.string(forKey: userDisplayNameDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return savedName.isEmpty ? "" : "\n\nthe user's name is \(savedName). use it now and then, naturally."
    }

    private static let companionVoiceResponseSystemPrompt = """
    you're orchestra, the user's friendly always-on companion that lives in their menu bar. you work alongside hermes, the user's background agent that runs on a separate always-on computer and can do long, hands-on work. The user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

    drawing on the screen:
    when explaining something on screen is clearer with a highlight, draw it (in addition to or instead of pointing). tags go before the point tag, several allowed, coordinates in screenshot pixels like pointing (add :screen2 for another monitor):
    [DRAW: circle x,y,radius]  [DRAW: box x1,y1,x2,y2]  [DRAW: arrow x1,y1,x2,y2]  [DRAW: label x,y short text]
    example: "these two numbers should match" [DRAW: box 410,220,560,250] [DRAW: box 410,520,560,550] [POINT:none]

    doing things on the user's mac (actions):
    you can act on this mac right away by adding action tags BEFORE the point tag. use them whenever the user asks you to play, pause, skip, open, go to, type, or change volume. keep the spoken line short ("playing it now", "opening notion").
    available actions, one per tag, several allowed:
    [ACTION: spotify play] [ACTION: spotify pause] [ACTION: spotify next] [ACTION: spotify previous]
    [ACTION: spotify play <what to play>] — e.g. [ACTION: spotify play lofi beats playlist] or [ACTION: spotify play blinding lights the weeknd]. a spotify link or spotify: uri also works.
    [ACTION: open_app <app name>] — e.g. [ACTION: open_app Notion]
    [ACTION: open_url <link>] — e.g. [ACTION: open_url https://example.com]
    [ACTION: volume <0-100>]
    [ACTION: type <text>] — types into the app in front. only when the user clearly asks you to type or fill something in.
    [ACTION: open_jobs] — opens their orchestra jobs folder.
    [ACTION: key <combo>] — e.g. [ACTION: key cmd+t], [ACTION: key return]
    [ACTION: scroll <lines>] — positive scrolls down, negative up
    [ACTION: click x,y] — one click at screenshot pixel x,y (add :screen2 for another monitor). for a single obvious click only; for anything multi-step use a takeover.
    never use an action to send messages, post, delete, or buy anything; for those, hand it to hermes as a job and say it'll be a draft.

    driving the screen (takeover):
    when the user says "do it for me", "fill this in", "set this up", or asks for something that needs several clicks and typing inside an app on their screen, say one short line ("okay, taking over, hold the hotkey to stop me") and add:
    [TAKEOVER: the goal in one clear sentence, with any details the user gave]
    a separate step-by-step loop will then look at the screen and click and type for them. it stops before anything irreversible (send, buy, delete) and asks them. when a browser is in front it can also click and type inside the web page directly.

    teaching (show me how):
    when the user wants to learn to do it themselves ("show me how", "teach me", "walk me through", "how do i …" for something that takes more than one step), say one short line ("sure, follow the blue cursor") and add:
    [SHOWME: what they want to learn, in one clear sentence]
    a guide will then point at each step and say it, and wait for them to do it before the next one. for a single step, just answer and point.

    thinking harder (escalation):
    if the question needs careful reasoning — tricky math, debugging code on screen, a long technical explanation, a hard decision — reply with only [SMARTER] and nothing else. a stronger model will answer instead. don't use it for normal chat.

    background jobs on this mac (mac jobs):
    for real work that needs the user's mac itself — their files, folders, mac apps, making a document or file on their mac, organizing downloads, converting or renaming files, coding in a local folder — start a mac job instead of a hermes job:
    [MACJOB: a clear, complete brief: what to do, the details, what to deliver and where]
    a local agent with a shell, files and spotlight does it and shows a live note page. it can't use the user's accounts (email, calendar).

    repeating jobs (routines):
    when the user asks for something on a schedule ("every morning", "every monday at 9", "every 2 hours"), add:
    [ROUTINE: <schedule> | <hermes or mac> | <brief>]
    schedule must be one of: daily HH:MM, weekdays HH:MM, <weekday> HH:MM (e.g. monday 09:00), every N hours, every N minutes (15 or more). 24-hour time.
    to stop one: [ROUTINE_STOP: words from its title]

    quick looks at the user's accounts:
    for a quick question about their email, calendar, files, notes or reminders ("what's on my calendar tomorrow", "any email from my manager"), say a short line like "checking with hermes, one sec" and add:
    [ASK_HERMES: the exact question, with the date range or names the user gave]
    the answer is read to them when it comes back (usually within a minute or two).

    handing work to hermes (jobs):
    you answer questions and guide the user on screen yourself. but when the user asks you to actually DO something that takes real work — research that needs many searches, comparing options, writing or building a file, installing something, organizing files, anything multi-step or longer than a quick answer — hand it to hermes as a background job.

    hermes can reach the user's connected accounts (like email, calendar, files, notes and reminders), use github, browse the web, and message the user. it runs on a separate always-on computer, not this mac.
    to do that, reply with one short spoken line confirming what you're handing off (like "on it, i'll have hermes dig into flights to tokyo and ping you when it's done"), then put a job tag BEFORE the point tag:
    [JOB: a clear, complete brief for hermes in plain english — what to do, the details the user gave, and what to deliver]
    the brief must stand on its own: hermes can't see the screen or this conversation, so include anything relevant you can see on screen (names, links, numbers) and anything the user said earlier.

    don't make a job for quick questions, explanations, or things you can point at. only one job tag per reply. if the user asks how a job is going or what hermes found, answer from the recent jobs list below.

    example:
    - user says "find me the three cheapest used macbook airs near me and put them in a doc": "on it, hermes will hunt those down and drop them in a doc for you. [JOB: find the three cheapest used macbook air listings near me right now. for each give price, model year, specs, condition, seller link. put them in a short markdown table in a file and reply with the file path and the table.] [POINT:none]"
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        speechOutputClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context —
                // unless the user's screen-sharing setting says not to for this question.
                let isScreenShared = ScreenPrivacySettings.mayCaptureScreen(forTranscript: transcript)
                var screenCaptures: [CompanionScreenCapture] = []
                if isScreenShared {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let systemPromptWithRecentJobs = Self.companionVoiceResponseSystemPrompt
                    + Self.userNamePromptLine
                    + "\n\nrecent jobs (newest first):\n"
                    + orchestraJobManager.recentJobsSummaryForPrompt()
                    + "\n\nrepeating routines:\n"
                    + orchestraJobManager.routinesSummaryForPrompt()
                    + (isScreenShared ? "" : "\n\nscreen sharing is OFF for this question: you cannot see the user's screen. don't point, draw, click or take over; if the user needs you to look, tell them to say \"look at my screen\" (or turn screen sharing on in the orchestra menu).")

                let firstReply = try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptWithRecentJobs,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )
                var fullResponseText = firstReply.text

                guard !Task.isCancelled else { return }

                // [SMARTER] = the fast model wants a stronger model for this one
                // (hard reasoning, math, code, long explanations). Say so, then
                // re-ask the same question with the smart model.
                if fullResponseText.contains("[SMARTER]") {
                    try? await speechOutputClient.speakText("give me a sec, thinking harder on this one.")
                    let smartModelName = await GeminiAPI.resolveSmartModel()
                    let smartGeminiAPI = GeminiAPI(model: smartModelName)
                    let smartReply = try await smartGeminiAPI.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: systemPromptWithRecentJobs
                            + "\n\nyou are the stronger model the user was escalated to. answer fully; never reply with [SMARTER].",
                        conversationHistory: historyForAPI,
                        userPrompt: transcript,
                        onTextChunk: { _ in }
                    )
                    fullResponseText = smartReply.text.replacingOccurrences(of: "[SMARTER]", with: "")
                    guard !Task.isCancelled else { return }
                }

                // [TAKEOVER: goal] = the user asked us to do something by driving their screen.
                let takeoverParseResult = Self.extractTagContent(named: "TAKEOVER", from: fullResponseText)
                fullResponseText = takeoverParseResult.remainingText

                // [SHOWME: goal] = the user wants to learn it: guide them step by step.
                let showMeParseResult = Self.extractTagContent(named: "SHOWME", from: fullResponseText)
                fullResponseText = showMeParseResult.remainingText

                // [ASK_HERMES: question] = quick read of the user's accounts; the answer is spoken when it arrives.
                let askHermesParseResult = Self.extractTagContent(named: "ASK_HERMES", from: fullResponseText)
                fullResponseText = askHermesParseResult.remainingText
                if let quickQuestion = askHermesParseResult.tagContent, HermesBridgeClient.isConfigured {
                    orchestraJobManager.startJob(
                        brief: "QUICK LOOK — answer in 2 to 4 short spoken sentences, no lists, no files: \(quickQuestion)",
                        spokenRequest: transcript,
                        place: .hermes,
                        isQuickLook: true
                    )
                }

                // [MACJOB: brief] = background job for the on-Mac agent.
                let macJobParseResult = Self.extractTagContent(named: "MACJOB", from: fullResponseText)
                fullResponseText = macJobParseResult.remainingText
                // [ROUTINE: schedule | hermes or mac | brief] and [ROUTINE_STOP: words]
                let routineParseResult = Self.extractTagContent(named: "ROUTINE", from: fullResponseText)
                fullResponseText = routineParseResult.remainingText
                let routineStopParseResult = Self.extractTagContent(named: "ROUTINE_STOP", from: fullResponseText)
                fullResponseText = routineStopParseResult.remainingText

                // Pull out a [JOB: ...] tag first (it can sit anywhere), then
                // parse the [POINT:...] tag from what's left.
                let jobParseResult = Self.extractJobBrief(from: fullResponseText)
                let actionParseResult = MacActionRunner.extractActions(from: jobParseResult.remainingText)
                let drawParseResult = Self.extractAllTagContents(named: "DRAW", from: actionParseResult.remainingText)
                if !drawParseResult.tagContents.isEmpty {
                    showScreenAnnotations(ScreenAnnotationParser.annotations(
                        fromDrawCommands: drawParseResult.tagContents, screenCaptures: screenCaptures))
                }
                let parseResult = Self.parsePointingCoordinates(from: drawParseResult.remainingText)
                var spokenText = parseResult.spokenText

                if let macJobBrief = macJobParseResult.tagContent {
                    orchestraJobManager.startJob(brief: macJobBrief, spokenRequest: transcript, place: .mac)
                }

                if let routineText = routineParseResult.tagContent {
                    let routinePieces = routineText.components(separatedBy: "|").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let routineScheduleText = routinePieces.first ?? ""
                    let routinePlace: OrchestraJobPlace = routinePieces.count >= 3 && routinePieces[1].lowercased() == "mac" ? .mac : .hermes
                    let routineBrief = routinePieces.count >= 3 ? routinePieces[2...].joined(separator: " | ") : (routinePieces.last ?? "")
                    if orchestraJobManager.addRoutine(scheduleText: routineScheduleText, place: routinePlace, brief: routineBrief) == nil {
                        spokenText = "i couldn't understand that schedule. try something like every weekday at eight thirty."
                    }
                }

                if let routineStopText = routineStopParseResult.tagContent {
                    let removedRoutineTitles = orchestraJobManager.removeRoutines(matching: routineStopText)
                    if removedRoutineTitles.isEmpty {
                        spokenText = "i couldn't find a routine like that."
                    }
                }

                if let jobBrief = jobParseResult.jobBrief {
                    if HermesBridgeClient.isConfigured {
                        orchestraJobManager.startJob(brief: jobBrief, spokenRequest: transcript)
                    } else {
                        spokenText = "i'd hand that to hermes, but the hermes bridge isn't set up yet. paste the hermes token under connections in the orchestra menu and ask me again."
                    }
                }

                // Run any [ACTION: ...] tags on this Mac (Spotify, apps, links,
                // volume, typing). If every action failed, say so instead of
                // pretending it worked.
                if !actionParseResult.actions.isEmpty {
                    let actionResults = await macActionRunner.runActions(actionParseResult.actions, screenCaptures: screenCaptures)
                    let failedActionResults = actionResults.filter { !$0.succeeded }
                    if !failedActionResults.isEmpty && failedActionResults.count == actionResults.count {
                        let failureReason = failedActionResults.first?.detail ?? "something went wrong"
                        spokenText = "hmm, i couldn't do that on your mac: \(failureReason)."
                    }
                }

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await speechOutputClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch is CancellationError {
                        // A newer reply replaced this one: stay quiet.
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }

                if let takeoverGoal = takeoverParseResult.tagContent {
                    startScreenTakeover(goal: takeoverGoal)
                } else if let walkthroughGoal = showMeParseResult.tagContent {
                    startScreenWalkthrough(goal: walkthroughGoal)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Live mode (Gemini Live two-way voice)

    @Published var isLiveModeEnabled: Bool = UserDefaults.standard.bool(forKey: "isLiveModeEnabled")
    @Published private(set) var isLiveSessionActive: Bool = false
    private var geminiLiveSession: GeminiLiveSession?

    func setLiveModeEnabled(_ enabled: Bool) {
        isLiveModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isLiveModeEnabled")
        if !enabled { geminiLiveSession?.stop() }
    }

    private func toggleLiveSession() {
        // A second tap ends the session — also while it's still connecting.
        if let geminiLiveSession,
           geminiLiveSession.liveState == .live || geminiLiveSession.liveState == .connecting {
            geminiLiveSession.stop()
            return
        }

        let liveSystemInstruction = Self.liveVoiceSystemPrompt
            + Self.userNamePromptLine
            + "\n\nrecent jobs (newest first):\n" + orchestraJobManager.recentJobsSummaryForPrompt()
            + "\n\nrepeating routines:\n" + orchestraJobManager.routinesSummaryForPrompt()
            + (ScreenSharingMode.current == .always
               ? ""
               : ScreenSharingMode.current == .never
                 ? "\n\nscreen sharing is OFF: you can't see the user's screen. don't point or take over."
                 : "\n\nyou only see the user's screen when the user asks you to look: then call look_at_screen first.")

        let toolHandlers = GeminiLiveSession.ToolHandlers(
            pointAt: { [weak self] normalizedX, normalizedY, label, screenCapture in
                // The screen agent owns the cursor while it works.
                guard let self, !self.isScreenTakeoverRunning else { return }
                let appKitPoint = ScreenControl.appKitGlobalPoint(
                    fromNormalizedPoint: CGPoint(x: normalizedX, y: normalizedY), in: screenCapture)
                self.detectedElementBubbleText = label
                self.detectedElementDisplayFrame = screenCapture.displayFrame
                self.detectedElementScreenLocation = appKitPoint
            },
            runMacAction: { [weak self] actionText in
                guard let self else { return "not available" }
                if self.isScreenTakeoverRunning {
                    return "not done: the screen agent is still working. wait for it to report back, or call stop_screen_takeover first."
                }
                let results = await self.macActionRunner.runActions([actionText])
                guard let result = results.first else { return "no result" }
                return result.succeeded ? "done" : "failed: \(result.detail ?? "error")"
            },
            startJob: { [weak self] place, brief in
                guard let self else { return "not available" }
                if place == .hermes && !HermesBridgeClient.isConfigured {
                    return "hermes isn't connected yet; tell the user to paste the hermes token under connections"
                }
                let job = self.orchestraJobManager.startJob(brief: brief, spokenRequest: brief, place: place)
                return "started job \"\(job.title)\" on \(place.rawValue). The user will be told when it's done."
            },
            takeOverScreen: { [weak self] goal in
                guard let self else { return "not available" }
                if ScreenSharingMode.current == .never {
                    return "screen sharing is set to never, so you can't take over. tell the user they can change it in the orchestra menu."
                }
                // Live keeps running: the takeover works in the background and
                // reports back into this conversation when it's done.
                self.startScreenTakeover(goal: goal)
                return "started. it's working on the screen now; say one short line like 'on it' and don't use mac_action or point_at until it reports back. if the user says stop, call stop_screen_takeover."
            },
            showMeHow: { [weak self] goal in
                guard let self else { return "not available" }
                if ScreenSharingMode.current == .never {
                    return "screen sharing is set to never, so you can't guide on screen. tell the user they can change it in the orchestra menu."
                }
                self.startScreenWalkthrough(goal: goal)
                return "started. say one short line like 'sure, follow the blue cursor'. you'll get a note for each step: say it briefly, then let them do it. if they say stop, call stop_screen_takeover."
            },
            runBrowserAction: { [weak self] action, elementIdentifier, text in
                guard let self else { return "not available" }
                if self.isScreenTakeoverRunning {
                    return "not done: the screen agent is still working. wait for it to report back, or call stop_screen_takeover first."
                }
                if ScreenSharingMode.current == .never && action.lowercased() == "read" {
                    return "screen sharing is set to never, so you can't read the page."
                }
                do {
                    switch action.lowercased() {
                    case "read":
                        return try BrowserControl.readPage()
                    case "click":
                        guard let elementIdentifier else { return "click needs an id from read" }
                        return try BrowserControl.clickElement(id: elementIdentifier)
                    case "type":
                        guard let elementIdentifier else { return "type needs an id from read" }
                        return try BrowserControl.typeIntoElement(id: elementIdentifier, text: text)
                    case "open":
                        return try BrowserControl.openAddress(text)
                    case "scroll":
                        return try BrowserControl.scrollPage(screens: Double(text) ?? 1)
                    case "back":
                        return try BrowserControl.goBack()
                    default:
                        return "unknown browser action \(action)"
                    }
                } catch {
                    return "failed: \(error.localizedDescription)"
                }
            },
            stopTakeover: { [weak self] in
                guard let self, self.isScreenTakeoverRunning else { return "nothing was running" }
                self.stopRunningScreenTakeover()
                return "stopped"
            },
            addRoutine: { [weak self] scheduleText, place, brief in
                guard let self else { return "not available" }
                guard let routine = self.orchestraJobManager.addRoutine(scheduleText: scheduleText, place: place, brief: brief) else {
                    return "couldn't read that schedule"
                }
                return "routine \"\(routine.title)\" saved (\(routine.scheduleText))"
            },
            recentJobsSummary: { [weak self] in
                self?.orchestraJobManager.recentJobsSummaryForPrompt() ?? "no jobs"
            }
        )

        let newLiveSession = GeminiLiveSession(systemInstructionText: liveSystemInstruction, toolHandlers: toolHandlers)
        newLiveSession.onStateChange = { [weak self] liveState in
            guard let self else { return }
            switch liveState {
            case .live:
                self.isLiveSessionActive = true
                self.voiceState = .listening
            case .connecting:
                self.voiceState = .processing
            case .idle:
                self.isLiveSessionActive = false
                self.voiceState = .idle
                self.currentAudioPowerLevel = 0
            case .failed(let reason):
                self.isLiveSessionActive = false
                self.voiceState = .idle
                self.currentAudioPowerLevel = 0
                print("⚠️ Live mode: \(reason)")
                Task { try? await self.speechOutputClient.speakText("live mode couldn't connect. \(reason)") }
            }
        }
        newLiveSession.onMicrophoneLevel = { [weak self] microphoneLevel in
            self?.currentAudioPowerLevel = microphoneLevel
        }
        geminiLiveSession = newLiveSession
        newLiveSession.start()
    }

    private static let liveVoiceSystemPrompt = """
    you're orchestra, the user's friendly voice companion on their mac, talking with them live. you see their screen through frames sent every few seconds. keep replies short and natural, like a friend sitting next to them; go deeper only when the user asks.

    tools:
    - point_at: fly the blue cursor to something on screen when showing them where to click helps. x,y are on a 0-1000 grid over the latest frame (0,0 top-left, 1000,1000 bottom-right).
    - mac_action: one quick thing right now (spotify, open apps and links, volume, scrolling, 'type <text>' into the field that has focus, 'key cmd+c' to copy what's already selected, 'key cmd+v' to paste).
    - take_over_screen: anything that needs clicking or selecting on screen (e.g. "copy this paragraph", "write this into that box", "fill this in"). it runs in the background while you stay in the conversation. write a goal that stands on its own: what to do, and the exact visible text or element you mean (resolve "this"/"that" from the screen and the conversation).
    - show_me_how: when the user wants to learn to do it themselves ("show me how", "teach me", "walk me through"). a guide points at each step and you'll be asked to say each step; they do the clicking.
    - stop_screen_takeover: when the user says stop or wait during a takeover or a walkthrough.
    - browser: when a web browser is in front — read the page (titles, buttons, fields and text, with ids), click or type by id, open an address, scroll, go back. more accurate than pointing for web pages; use read first to get ids.
    - start_job: real work in the background. place "hermes" for research, the web, and their accounts (email, calendar, files, notes, reminders, github). place "mac" for their mac's files and apps. the brief must stand on its own.
    - add_routine: when the user wants something on a schedule.
    - recent_jobs: when the user asks how a job went.

    rules: confirm before anything that deletes, sends or posts to other people, or spends money (those become drafts or their last click). never claim you did something unless the tool said so. never read out passwords or codes.
    """

    // MARK: - Screen Takeover

    /// The running "drive my screen" session, if any. Holding the hotkey cancels it.
    private var currentScreenTakeoverTask: Task<Void, Never>?
    /// Counts takeover starts, so an older one finishing doesn't clear the flag.
    private var takeoverStartNumber = 0
    /// Set when the user stopped that takeover on purpose (tap or "stop").
    private var stoppedTakeoverStartNumber = -1
    /// True until the takeover task has really returned, so nothing else
    /// clicks or types while an in-flight action is still finishing.
    private var isScreenTakeoverRunning = false

    /// Stops the takeover: no new actions start; the flag clears when the task returns.
    private func stopRunningScreenTakeover() {
        stoppedTakeoverStartNumber = takeoverStartNumber
        currentScreenTakeoverTask?.cancel()
    }

    private func startScreenTakeover(goal: String) {
        startScreenTask(goal: goal, isWalkthrough: false)
    }

    /// "Show me how": point + say each step while the user does it themselves.
    private func startScreenWalkthrough(goal: String) {
        startScreenTask(goal: goal, isWalkthrough: true)
    }

    private func startScreenTask(goal: String, isWalkthrough: Bool) {
        currentScreenTakeoverTask?.cancel()
        if ScreenSharingMode.current == .never {
            Task { try? await speechOutputClient.speakText("screen sharing is set to never, so i can't take over your screen. you can change that in the orchestra menu.") }
            return
        }
        takeoverStartNumber += 1
        let thisTakeoverStartNumber = takeoverStartNumber
        isScreenTakeoverRunning = true
        currentScreenTakeoverTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.takeoverStartNumber == thisTakeoverStartNumber {
                    self.isScreenTakeoverRunning = false
                }
            }
            // Let the spoken "on it" line finish so we don't talk over ourselves.
            while !self.isLiveSessionActive && self.speechOutputClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            let smartModelName = await GeminiAPI.resolveSmartModel()
            let outcome: ScreenTakeoverSession.Outcome
            if isWalkthrough {
                let walkthroughSession = GuidedWalkthroughSession(
                    goal: goal,
                    geminiAPI: GeminiAPI(model: smartModelName),
                    speakInstruction: { [weak self] instructionText in
                        guard let self else { return }
                        if self.isLiveSessionActive, let liveSession = self.geminiLiveSession {
                            await liveSession.sendTextTurn("(walkthrough step from the screen guide, not the user) say this to the user in a few words, nothing else: \(instructionText)")
                        } else {
                            try? await self.speechOutputClient.speakText(instructionText)
                        }
                    },
                    showPointer: { [weak self] appKitPoint, displayFrame, instructionText in
                        guard let self else { return }
                        if !self.isLiveSessionActive { self.voiceState = .idle }
                        self.detectedElementBubbleText = instructionText
                        self.detectedElementDisplayFrame = displayFrame
                        self.detectedElementScreenLocation = appKitPoint
                    }
                )
                outcome = await walkthroughSession.run()
            } else {
                let takeoverSession = ScreenTakeoverSession(
                    goal: goal,
                    geminiAPI: GeminiAPI(model: smartModelName),
                    macActionRunner: self.macActionRunner,
                    showCursorAt: { [weak self] appKitPoint, displayFrame in
                        guard let self else { return }
                        // In Live mode the conversation is still listening; leave its state alone.
                        if !self.isLiveSessionActive { self.voiceState = .idle }
                        self.detectedElementBubbleText = "here"
                        self.detectedElementDisplayFrame = displayFrame
                        self.detectedElementScreenLocation = appKitPoint
                    }
                )
                outcome = await takeoverSession.run()
            }
            OrchestraLog.write("\(isWalkthrough ? "🧭 Walkthrough" : "🖱️ Takeover") ended (finished: \(outcome.finished)): \(outcome.spokenSummary)")
            let wasStoppedByUser = self.stoppedTakeoverStartNumber == thisTakeoverStartNumber
            self.conversationHistory.append((
                userTranscript: "(\(isWalkthrough ? "show-me-how walkthrough" : "screen takeover") \(wasStoppedByUser ? "stopped by the user" : "ended")) goal: \(goal)",
                assistantResponse: outcome.spokenSummary
            ))
            // Stopped in Live mode on purpose: the live voice already answered "stopped".
            if wasStoppedByUser && self.isLiveSessionActive { return }
            if self.isLiveSessionActive, let liveSession = self.geminiLiveSession {
                // Live mode: let the live voice say how it went.
                await liveSession.sendTextTurn("(note from the screen agent, not the user) the \(isWalkthrough ? "walkthrough" : "screen takeover") \(outcome.finished ? "finished" : "stopped"): \(outcome.spokenSummary) — tell the user in one short sentence; if it asked a question, ask them that question.")
            } else {
                try? await self.speechOutputClient.speakText(outcome.spokenSummary)
            }
        }
    }

    /// Finds every [NAME: content] tag in the reply and removes them all.
    static func extractAllTagContents(named tagName: String, from responseText: String) -> (tagContents: [String], remainingText: String) {
        let pattern = "\\[\(tagName):\\s*([^\\]]+?)\\s*\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ([], responseText) }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let tagContents = regex.matches(in: responseText, range: fullRange).compactMap { match in
            Range(match.range(at: 1), in: responseText).map { String(responseText[$0]) }
        }
        let remainingText = regex.stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tagContents, remainingText)
    }

    /// Finds a [NAME: content] tag anywhere in the reply and removes it.
    static func extractTagContent(named tagName: String, from responseText: String) -> (tagContent: String?, remainingText: String) {
        let pattern = "\\[\(tagName):\\s*([\\s\\S]*?)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let contentRange = Range(match.range(at: 1), in: responseText),
              let wholeTagRange = Range(match.range, in: responseText) else {
            return (nil, responseText)
        }
        let tagContent = String(responseText[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var remainingText = responseText
        remainingText.removeSubrange(wholeTagRange)
        return (tagContent.isEmpty ? nil : tagContent, remainingText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while speechOutputClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = hasGeminiAPIKey
            ? "Something went wrong talking to Gemini. Check your key and connection in the Orchestra menu."
            : "I need a Gemini API key first. Paste one in the Orchestra menu."
        // Goes through the same speech client so a new reply can interrupt it.
        speechOutputClient.speakWithMacVoiceNow(utterance)
        voiceState = .responding
    }

    // MARK: - Job Tag Parsing

    /// Finds a [JOB: ...] tag anywhere in the reply. Returns the brief (if
    /// any) and the reply with the tag removed, so the POINT parser and TTS
    /// never see it.
    static func extractJobBrief(from responseText: String) -> (jobBrief: String?, remainingText: String) {
        let pattern = #"\[JOB:\s*([\s\S]*?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let briefRange = Range(match.range(at: 1), in: responseText),
              let wholeTagRange = Range(match.range, in: responseText) else {
            return (nil, responseText)
        }
        let jobBrief = String(responseText[briefRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var remainingText = responseText
        remainingText.removeSubrange(wholeTagRange)
        remainingText = remainingText
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (jobBrief.isEmpty ? nil : jobBrief, remainingText)
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        guard ScreenSharingMode.current != .never else { return }
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await geminiAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

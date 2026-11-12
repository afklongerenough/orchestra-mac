//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var geminiAPIKeyInput: String = ""
    @State private var hermesBridgeURLInput: String = ""
    @ObservedObject private var orchestraUpdater = OrchestraUpdater.shared
    @State private var spotifyAccountStatusText: String = ""
    @State private var isConnectingSpotifyAccount = false
    /// Saved as soon as it's typed (no Save needed).
    @AppStorage("userDisplayName") private var userDisplayNameInput: String = ""
    @State private var hermesBridgeTokenInput: String = ""
    @State private var isShowingConnectionSettings: Bool = false
    @State private var spotifyClientIDInput: String = ""
    @State private var openCodeAPIKeyInput: String = ""
    @AppStorage(BrainProvider.defaultsKey) private var brainProviderRawValue: String = BrainProvider.opencodeGo.rawValue
    @State private var hasOpenCodeKeySaved: Bool = KeychainStore.read(.openCodeAPIKey) != nil
    @State private var spotifyClientSecretInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                brainPickerRow
                    .padding(.horizontal, 16)

                if !(brainProviderRawValue == BrainProvider.opencodeGo.rawValue && hasOpenCodeKeySaved) {
                    modelPickerRow
                        .padding(.horizontal, 16)
                }

                liveModeToggleRow
                    .padding(.horizontal, 16)
                wakeWordToggleRow
                    .padding(.horizontal, 16)

                voicePickerRow
                    .padding(.horizontal, 16)

                screenPrivacyRows
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                OrchestraJobsListView(orchestraJobManager: companionManager.orchestraJobManager)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                connectionSettingsSection
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            updateSection
                .padding(.horizontal, 16)
                .padding(.top, 10)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Orchestra")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasGeminiAPIKey {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paste your Gemini API key to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Get a free one at aistudio.google.com. It's saved in your Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Orchestra.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the permissions below to keep using Orchestra.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hey there. This is Orchestra.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Your voice buddy that sees your screen, points at things, and hands bigger jobs to Hermes. Built on Farza's open-source Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("It only takes a screenshot when you hold the hotkey.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasGeminiAPIKey {
                VStack(spacing: 8) {
                    SecureField("Gemini API key", text: $geminiAPIKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.saveGeminiAPIKey(geminiAPIKeyInput)
                        geminiAPIKeyInput = ""
                    }) {
                        Text("Save Key")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Screen Privacy

    @AppStorage(ScreenSharingMode.defaultsKey) private var screenSharingModeRawValue: String = ScreenSharingMode.always.rawValue
    @AppStorage(ScreenPrivacySettings.captureCueEnabledDefaultsKey) private var isCaptureCueEnabled: Bool = true
    @State private var hiddenAppBundleIdentifiers: Set<String> = ScreenPrivacySettings.hiddenAppBundleIdentifiers

    private var screenPrivacyRows: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Screen sharing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Menu {
                    ForEach(ScreenSharingMode.allCases, id: \.rawValue) { sharingMode in
                        Button(sharingMode.menuTitle) { screenSharingModeRawValue = sharingMode.rawValue }
                    }
                } label: {
                    Text((ScreenSharingMode(rawValue: screenSharingModeRawValue) ?? .always).shortTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
            }
            .padding(.vertical, 4)

            HStack {
                Text("Hidden apps")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Menu {
                    Text("Checked apps never appear in screenshots")
                    Divider()
                    ForEach(ScreenPrivacySettings.runningAppsForMenu(), id: \.bundleIdentifier) { runningApp in
                        Button((hiddenAppBundleIdentifiers.contains(runningApp.bundleIdentifier) ? "✓ " : "    ") + runningApp.name) {
                            let shouldHide = !hiddenAppBundleIdentifiers.contains(runningApp.bundleIdentifier)
                            ScreenPrivacySettings.setApp(runningApp.bundleIdentifier, hidden: shouldHide)
                            hiddenAppBundleIdentifiers = ScreenPrivacySettings.hiddenAppBundleIdentifiers
                        }
                    }
                } label: {
                    Text("\(hiddenAppBundleIdentifiers.count) hidden")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
            }
            .padding(.vertical, 4)

            HStack {
                Text("Sound + flash on screenshot")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Toggle("", isOn: $isCaptureCueEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .pointerCursor()
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Brain Picker (OpenCode Go vs Gemini)

    private var brainPickerRow: some View {
        HStack {
            Text("Brain")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Menu {
                Button(hasOpenCodeKeySaved ? "OpenCode Go · DeepSeek V4.1 Flash" : "OpenCode Go (add key under Connections)") {
                    brainProviderRawValue = BrainProvider.opencodeGo.rawValue
                }
                .disabled(!hasOpenCodeKeySaved)
                Button("Gemini (free tier, ~20 requests/day per model)") {
                    brainProviderRawValue = BrainProvider.gemini.rawValue
                }
            } label: {
                Text(brainProviderRawValue == BrainProvider.opencodeGo.rawValue && hasOpenCodeKeySaved
                     ? "DeepSeek · OpenCode Go"
                     : "Gemini")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Voice Picker

    @AppStorage(SpeechOutputClient.naturalVoiceEnabledDefaultsKey) private var isNaturalVoiceEnabled: Bool = true
    @AppStorage(SpeechOutputClient.naturalVoiceNameDefaultsKey) private var naturalVoiceName: String = "Achird"

    private var voicePickerRow: some View {
        HStack {
            Text("Voice")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Menu {
                Button("Mac voice (instant, robotic)") { isNaturalVoiceEnabled = false }
                Divider()
                ForEach(0..<SpeechOutputClient.naturalVoiceOptions.count, id: \.self) { voiceOptionIndex in
                    let voiceOption = SpeechOutputClient.naturalVoiceOptions[voiceOptionIndex]
                    Button("\(voiceOption.name) · \(voiceOption.style)") {
                        naturalVoiceName = voiceOption.name
                        isNaturalVoiceEnabled = true
                    }
                }
            } label: {
                Text(isNaturalVoiceEnabled
                     ? (companionManager.isUsingMacVoiceFallback ? "\(naturalVoiceName) (fell back to Mac voice)" : naturalVoiceName)
                     : "Mac voice")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Live Mode Toggle

    private var liveModeToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live conversation")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.isLiveModeEnabled
                     ? "Tap Control+Option to start/stop. Shares your screen with Gemini every 3s while on."
                     : "Off: hold Control+Option to talk")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { companionManager.isLiveModeEnabled },
                set: { companionManager.setLiveModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Wake word

    private var wakeWordToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\"Hey Clicky\"")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.isWakeWordEnabled
                     ? "Say it to start a live chat. Heard on this Mac only, nothing is recorded. Status: \(companionManager.wakeWordStatusText)"
                     : "Off: say \"hey clicky\" to start a live chat, hands-free")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { companionManager.isWakeWordEnabled },
                set: { companionManager.setWakeWordEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                ForEach(GeminiAPI.availableModels) { geminiModel in
                    modelOptionButton(label: geminiModel.label, modelID: geminiModel.id)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Connection Settings (Gemini key + Hermes bridge)

    private var connectionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                if !isShowingConnectionSettings {
                    hermesBridgeURLInput = companionManager.hermesBridgeURLText
                }
                isShowingConnectionSettings.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isShowingConnectionSettings ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Connections")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(HermesBridgeClient.isConfigured ? "Hermes linked" : "Hermes not set up")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .foregroundColor(DS.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isShowingConnectionSettings {
                connectionTextField(placeholder: "Your name (optional)", text: $userDisplayNameInput, isSecure: false)
                connectionTextField(placeholder: "Hermes bridge URL (https://…/mcp)", text: $hermesBridgeURLInput, isSecure: false)
                connectionTextField(
                    placeholder: companionManager.hasHermesBridgeToken ? "Hermes token (saved — paste to replace)" : "Hermes token (if the bridge needs one)",
                    text: $hermesBridgeTokenInput,
                    isSecure: true
                )
                connectionTextField(placeholder: "New Gemini API key (optional)", text: $geminiAPIKeyInput, isSecure: true)
                connectionTextField(
                    placeholder: hasOpenCodeKeySaved ? "OpenCode Go key (saved — paste to replace)" : "OpenCode Go key (oc_sk_…)",
                    text: $openCodeAPIKeyInput,
                    isSecure: true
                )
                connectionTextField(
                    placeholder: MacActionRunner.hasSpotifyWebAPIKeys ? "Spotify client ID (saved — paste to replace)" : "Spotify client ID (optional, for \"play X\")",
                    text: $spotifyClientIDInput,
                    isSecure: false
                )
                connectionTextField(placeholder: "Spotify client secret (optional)", text: $spotifyClientSecretInput, isSecure: true)
                spotifyAccountRow

                Button(action: {
                    companionManager.saveHermesBridgeSettings(
                        bridgeURLText: hermesBridgeURLInput,
                        bridgeToken: hermesBridgeTokenInput
                    )
                    if !geminiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        companionManager.saveGeminiAPIKey(geminiAPIKeyInput)
                    }
                    if !spotifyClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KeychainStore.write(spotifyClientIDInput, for: .spotifyClientID)
                    }
                    if !spotifyClientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KeychainStore.write(spotifyClientSecretInput, for: .spotifyClientSecret)
                    }
                    spotifyClientIDInput = ""
                    spotifyClientSecretInput = ""
                    if !openCodeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        KeychainStore.write(openCodeAPIKeyInput, for: .openCodeAPIKey)
                    }
                    openCodeAPIKeyInput = ""
                    hasOpenCodeKeySaved = KeychainStore.read(.openCodeAPIKey) != nil
                    hermesBridgeTokenInput = ""
                    geminiAPIKeyInput = ""
                    isShowingConnectionSettings = false
                }) {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private func connectionTextField(placeholder: String, text: Binding<String>, isSecure: Bool) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Spotify account

    /// Lets "play <song>" use the user's recently played and top tracks.
    private var spotifyAccountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(SpotifyLibrary.shared.isAccountConnected ? "Spotify history: connected" : "Spotify history: this Mac only")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                if isConnectingSpotifyAccount {
                    ProgressView().controlSize(.mini)
                } else if SpotifyLibrary.shared.isAccountConnected {
                    Button("Disconnect") {
                        SpotifyLibrary.shared.disconnectAccount()
                        spotifyAccountStatusText = "disconnected"
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                } else {
                    Button("Connect account") {
                        isConnectingSpotifyAccount = true
                        Task {
                            spotifyAccountStatusText = await SpotifyLibrary.shared.connectAccount()
                            isConnectingSpotifyAccount = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                    .pointerCursor()
                }
            }
            if !spotifyAccountStatusText.isEmpty {
                Text(spotifyAccountStatusText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Updates

    private var updateSection: some View {
        HStack(spacing: 8) {
            Text("Build \(orchestraUpdater.currentBuildNumber)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            switch orchestraUpdater.updateState {
            case .idle:
                checkForUpdatesButton
            case .upToDate:
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                checkForUpdatesButton
            case .failed(let failureMessage):
                Text(failureMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .help(failureMessage)
                checkForUpdatesButton
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            case .available(let availableBuildNumber):
                Button("Update to build \(availableBuildNumber)") {
                    Task { await orchestraUpdater.installAvailableUpdate() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
                .pointerCursor()
            case .installing(let currentStep):
                ProgressView().controlSize(.mini)
                Text(currentStep.prefix(1).uppercased() + currentStep.dropFirst() + "…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var checkForUpdatesButton: some View {
        Button("Check for updates") {
            Task { await orchestraUpdater.checkForUpdates() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(DS.Colors.textSecondary)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Orchestra")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

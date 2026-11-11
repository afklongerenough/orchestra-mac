//
//  ScreenPrivacySettings.swift
//  leanring-buddy
//
//  the user's control over when Orchestra sees the screen:
//    • Screen sharing mode — Always / Only when asked / Never
//      ("only when asked" = the question mentions looking, the screen, "this", …)
//    • Hidden apps — their windows are left out of every screenshot
//      (they show as whatever is behind them, usually the desktop)
//    • Capture cue — a soft sound + white flash each time a screenshot is taken
//
//  Also OrchestraLog: a small log file at ~/Orchestra/orchestra.log so
//  problems on the user's Mac (Live mode, models) can be read after the fact.
//

import AppKit
import Foundation

enum ScreenSharingMode: String, CaseIterable {
    case always
    case onlyWhenAsked
    case never

    static let defaultsKey = "screenSharingMode"

    static var current: ScreenSharingMode {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ScreenSharingMode.init(rawValue:)) ?? .always
    }

    var menuTitle: String {
        switch self {
        case .always: return "Always (when I talk)"
        case .onlyWhenAsked: return "Only when I ask it to look"
        case .never: return "Never"
        }
    }

    var shortTitle: String {
        switch self {
        case .always: return "Always"
        case .onlyWhenAsked: return "When asked"
        case .never: return "Never"
        }
    }
}

enum ScreenPrivacySettings {
    static let hiddenAppBundleIdentifiersDefaultsKey = "hiddenAppBundleIdentifiers"
    static let captureCueEnabledDefaultsKey = "screenCaptureCueEnabled"

    /// Password managers are hidden by default.
    static let defaultHiddenAppBundleIdentifiers = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.bitwarden.desktop"
    ]

    static var hiddenAppBundleIdentifiers: Set<String> {
        let savedIdentifiers = UserDefaults.standard.stringArray(forKey: hiddenAppBundleIdentifiersDefaultsKey)
        return Set(savedIdentifiers ?? defaultHiddenAppBundleIdentifiers)
    }

    static func setApp(_ bundleIdentifier: String, hidden isHidden: Bool) {
        var identifiers = hiddenAppBundleIdentifiers
        if isHidden { identifiers.insert(bundleIdentifier) } else { identifiers.remove(bundleIdentifier) }
        UserDefaults.standard.set(Array(identifiers).sorted(), forKey: hiddenAppBundleIdentifiersDefaultsKey)
    }

    static var isCaptureCueEnabled: Bool {
        UserDefaults.standard.object(forKey: captureCueEnabledDefaultsKey) as? Bool ?? true
    }

    /// For "only when asked": does this question want Orchestra to look?
    /// Errs toward privacy: the newest sentence that mentions looking decides,
    /// and any "don't / no need / never …" in it means no.
    static func transcriptAsksToLook(_ transcript: String) -> Bool {
        let lookWordsPattern = #"\b(look|see|seeing|screen|watch|read|point|where|click|show|this|that|here|these|those|which one|on my)\b"#
        let negationPattern = #"\b(don['’]?t|do not|doesn['’]?t|never|no need|needn['’]?t|not (look|see|watch|read)|stop (looking|watching)|without (looking|seeing))\b"#
        let sentences = transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let newestLookSentence = sentences.last(where: {
            $0.range(of: lookWordsPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return false }
        // Check from that sentence to the end, so "look at my email. no, don't." is a no.
        let newestLookSentenceIndex = sentences.lastIndex(of: newestLookSentence) ?? sentences.count - 1
        let textFromLookSentenceOn = sentences[newestLookSentenceIndex...].joined(separator: ". ")
        let isRetracted = textFromLookSentenceOn.range(of: negationPattern, options: [.regularExpression, .caseInsensitive]) != nil
            || textFromLookSentenceOn.range(of: #"(^|\. )(no|stop|nope|never mind|nevermind)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        return !isRetracted
    }

    /// Whether a push-to-talk question may include a screenshot.
    static func mayCaptureScreen(forTranscript transcript: String) -> Bool {
        switch ScreenSharingMode.current {
        case .always: return true
        case .onlyWhenAsked: return transcriptAsksToLook(transcript)
        case .never: return false
        }
    }

    /// Regular apps that are running now, for the "Hidden apps" menu.
    static func runningAppsForMenu() -> [(name: String, bundleIdentifier: String)] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        var seenIdentifiers = Set<String>()
        var apps: [(name: String, bundleIdentifier: String)] = []
        for runningApp in NSWorkspace.shared.runningApplications where runningApp.activationPolicy == .regular {
            guard let bundleIdentifier = runningApp.bundleIdentifier,
                  bundleIdentifier != ownBundleIdentifier,
                  !seenIdentifiers.contains(bundleIdentifier) else { continue }
            seenIdentifiers.insert(bundleIdentifier)
            apps.append((name: runningApp.localizedName ?? bundleIdentifier, bundleIdentifier: bundleIdentifier))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Notification.Name {
    /// Posted right after a screenshot is taken (for the flash + sound cue).
    static let orchestraScreenCaptured = Notification.Name("orchestraScreenCaptured")
}

/// Append-only log at ~/Orchestra/orchestra.log (trimmed when it passes ~1 MB).
enum OrchestraLog {
    private static let logQueue = DispatchQueue(label: "orchestra.log")
    private static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Orchestra", isDirectory: true)
        .appendingPathComponent("orchestra.log")

    static func write(_ message: String) {
        print(message)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        logQueue.async {
            try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
               let fileSize = attributes[.size] as? Int, fileSize > 1_000_000 {
                try? FileManager.default.removeItem(at: logFileURL)
            }
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(Data(line.utf8))
                try? fileHandle.close()
            } else {
                try? Data(line.utf8).write(to: logFileURL)
            }
        }
    }
}

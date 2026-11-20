//
//  OrchestraLanguageSettings.swift
//  leanring-buddy
//
//  Which language Orchestra answers in, and which language push-to-talk
//  listens for. Live mode (Gemini) understands many languages by itself;
//  push-to-talk uses Apple's speech recognizer, which supports fewer.
//

import Foundation
import Speech

enum OrchestraLanguageSettings {
    static let replyLanguageDefaultsKey = "orchestraReplyLanguage"
    static let dictationLocaleDefaultsKey = "dictationLocaleIdentifier"
    static let captionsEnabledDefaultsKey = "captionsEnabled"

    /// "auto" = answer in whatever language the user spoke.
    static let replyLanguageChoices = [
        "auto", "English", "Burmese", "Chinese", "Japanese", "Korean", "Thai",
        "Vietnamese", "Hindi", "Spanish", "French", "German", "Portuguese", "Arabic"
    ]

    static var replyLanguage: String {
        UserDefaults.standard.string(forKey: replyLanguageDefaultsKey) ?? "auto"
    }

    static var areCaptionsEnabled: Bool {
        UserDefaults.standard.object(forKey: captionsEnabledDefaultsKey) as? Bool ?? true
    }

    /// Added to every system prompt.
    static var replyLanguagePromptLine: String {
        if replyLanguage == "auto" {
            return "\n\nlanguage: reply in the same language the user speaks to you in (they may switch between english, burmese and others). keep tags like [POINT:...] and tool names in english."
        }
        return "\n\nlanguage: always reply in \(replyLanguage), whatever language the user speaks. keep tags like [POINT:...] and tool names in english."
    }

    /// The locale push-to-talk listens in (nil = the Mac's own language).
    static var dictationLocale: Locale? {
        guard let identifier = UserDefaults.standard.string(forKey: dictationLocaleDefaultsKey), !identifier.isEmpty else { return nil }
        return Locale(identifier: identifier)
    }

    /// Languages Apple's recognizer can do, for the menu (name, identifier).
    static func dictationLocaleChoices() -> [(name: String, identifier: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { supportedLocale in
                (name: Locale.current.localizedString(forIdentifier: supportedLocale.identifier) ?? supportedLocale.identifier,
                 identifier: supportedLocale.identifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

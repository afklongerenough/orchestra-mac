//
//  MacActionRunner.swift
//  leanring-buddy
//
//  Runs small "do it on my Mac" actions the voice model asks for with
//  [ACTION: ...] tags — the local equivalents of HeyClicky's voice tools
//  (play_on_spotify, launch_app, open_url, type_text, ...), written from
//  scratch for Orchestra.
//
//  Supported tags (one per tag, several tags allowed in one reply):
//    [ACTION: spotify play]            resume / start playback
//    [ACTION: spotify pause]
//    [ACTION: spotify next]  /  [ACTION: spotify previous]
//    [ACTION: spotify play <what>]     e.g. "spotify play lofi beats playlist"
//                                      (uses the Spotify Web API to find it if
//                                      a client id/secret is saved; otherwise
//                                      opens Spotify's search for it)
//    [ACTION: spotify play spotify:track:...] or an open.spotify.com link
//    [ACTION: open_app <app name>]     e.g. "open_app Notion"
//    [ACTION: open_url <https://...>]
//    [ACTION: volume <0-100>]
//    [ACTION: type <text>]             types into the frontmost app
//    [ACTION: open_jobs]               opens ~/Orchestra/Jobs
//
//  Apple Events (Spotify, volume) make macOS ask once per target app:
//  "Orchestra wants to control Spotify".
//

import AppKit
import Foundation

struct MacActionResult {
    let actionDescription: String
    let succeeded: Bool
    let detail: String?
}

@MainActor
final class MacActionRunner {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var cachedSpotifyAccessToken: String?
    private var cachedSpotifyAccessTokenExpiryDate: Date = .distantPast

    // MARK: - Tag parsing

    /// Pulls every [ACTION: ...] tag out of a reply. Returns the actions in
    /// order and the reply with the tags removed (so TTS never reads them).
    static func extractActions(from responseText: String) -> (actions: [String], remainingText: String) {
        let pattern = #"\[ACTION:\s*([^\]]+?)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], responseText)
        }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, range: fullRange)
        let actions: [String] = matches.compactMap { match in
            guard let actionRange = Range(match.range(at: 1), in: responseText) else { return nil }
            return String(responseText[actionRange])
        }
        let remainingText = regex
            .stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (actions, remainingText)
    }

    // MARK: - Running actions

    /// `screenCaptures` are the screenshots the model just looked at; they're
    /// needed only for click actions (to map screenshot pixels to the screen).
    func runActions(_ actionTexts: [String], screenCaptures: [CompanionScreenCapture] = []) async -> [MacActionResult] {
        var results: [MacActionResult] = []
        for actionText in actionTexts {
            let result = await runAction(actionText, screenCaptures: screenCaptures)
            print("🛠️ Mac action \"\(actionText)\" → \(result.succeeded ? "ok" : "failed") \(result.detail ?? "")")
            results.append(result)
        }
        return results
    }

    private func runAction(_ actionText: String, screenCaptures: [CompanionScreenCapture]) async -> MacActionResult {
        let trimmedActionText = actionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSpaceIndex = trimmedActionText.firstIndex(of: " ")
        let actionName = (firstSpaceIndex.map { String(trimmedActionText[..<$0]) } ?? trimmedActionText).lowercased()
        let actionArgument = firstSpaceIndex.map {
            String(trimmedActionText[trimmedActionText.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
        } ?? ""

        switch actionName {
        case "spotify":
            return await runSpotifyAction(actionArgument)
        case "open_app", "launch_app":
            return openApplication(named: actionArgument)
        case "open_url":
            return openURL(actionArgument)
        case "volume":
            return setOutputVolume(actionArgument)
        case "type", "type_text":
            return typeTextIntoFrontmostApp(actionArgument)
        case "key", "press":
            if let blockReason = Self.keyPressBlockReason(actionArgument) {
                return MacActionResult(actionDescription: trimmedActionText, succeeded: false, detail: blockReason)
            }
            let recognized = ScreenControl.pressKeyCombination(actionArgument)
            return MacActionResult(actionDescription: trimmedActionText, succeeded: recognized,
                                   detail: recognized ? nil : "unknown key \(actionArgument)")
        case "scroll":
            let scrollLineCount = Int(actionArgument.filter { $0.isNumber || $0 == "-" }) ?? 5
            ScreenControl.scroll(lines: scrollLineCount)
            return MacActionResult(actionDescription: trimmedActionText, succeeded: true, detail: nil)
        case "click", "double_click", "right_click":
            guard let parsedPointArgument = ScreenTakeoverSession.parsePointArgument(actionArgument),
                  let targetScreenCapture = ScreenTakeoverSession.screenCapture(number: parsedPointArgument.1, in: screenCaptures) else {
                return MacActionResult(actionDescription: trimmedActionText, succeeded: false, detail: "couldn't tell where to click")
            }
            let appKitPoint = ScreenControl.appKitGlobalPoint(fromScreenshotPoint: parsedPointArgument.0, in: targetScreenCapture)
            if let irreversibleLabel = ScreenControl.irreversibleControlLabel(atAppKitGlobalPoint: appKitPoint) {
                return MacActionResult(actionDescription: trimmedActionText, succeeded: false,
                                       detail: "i'll leave that click to you, since it's \(irreversibleLabel)")
            }
            let clickKind: ScreenControl.MouseClickKind =
                actionName == "double_click" ? .double : (actionName == "right_click" ? .right : .left)
            ScreenControl.click(atAppKitGlobalPoint: appKitPoint, kind: clickKind)
            return MacActionResult(actionDescription: trimmedActionText, succeeded: true, detail: nil)
        case "open_jobs":
            NSWorkspace.shared.open(OrchestraJobManager.jobsRootFolderURL)
            return MacActionResult(actionDescription: trimmedActionText, succeeded: true, detail: nil)
        default:
            return MacActionResult(actionDescription: trimmedActionText, succeeded: false, detail: "unknown action")
        }
    }

    // MARK: - Spotify

    private func runSpotifyAction(_ spotifyArgument: String) async -> MacActionResult {
        let description = "spotify \(spotifyArgument)"
        let lowercasedArgument = spotifyArgument.lowercased()

        switch lowercasedArgument {
        case "play", "resume":
            return runAppleScript(#"tell application "Spotify" to play"#, description: description)
        case "pause", "stop":
            return runAppleScript(#"tell application "Spotify" to pause"#, description: description)
        case "next", "skip", "next track":
            return runAppleScript(#"tell application "Spotify" to next track"#, description: description)
        case "previous", "back", "previous track":
            return runAppleScript(#"tell application "Spotify" to previous track"#, description: description)
        default:
            break
        }

        guard lowercasedArgument.hasPrefix("play ") else {
            return MacActionResult(actionDescription: description, succeeded: false, detail: "unknown spotify command")
        }
        let whatToPlay = String(spotifyArgument.dropFirst("play ".count)).trimmingCharacters(in: .whitespaces)

        // Already a Spotify URI or link: play it directly.
        if let spotifyURI = Self.spotifyURI(fromLinkOrURI: whatToPlay) {
            return playSpotifyURI(spotifyURI, description: description)
        }

        // Search with the Web API when the user has saved a client id/secret.
        if let foundURI = await searchSpotifyForURI(query: whatToPlay) {
            return playSpotifyURI(foundURI, description: description)
        }

        // Fallback: open Spotify's own search page for it.
        let encodedQuery = whatToPlay.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? whatToPlay
        if let searchURL = URL(string: "spotify:search:\(encodedQuery)") {
            NSWorkspace.shared.open(searchURL)
            return MacActionResult(actionDescription: description, succeeded: true,
                                   detail: "opened spotify search (add spotify keys under connections to auto-play)")
        }
        return MacActionResult(actionDescription: description, succeeded: false, detail: "couldn't build search link")
    }

    private func playSpotifyURI(_ spotifyURI: String, description: String) -> MacActionResult {
        let escapedURI = spotifyURI.replacingOccurrences(of: "\"", with: "")
        return runAppleScript(#"tell application "Spotify" to play track "\#(escapedURI)""#, description: description)
    }

    /// Turns "https://open.spotify.com/track/ID?si=..." or "spotify:track:ID" into "spotify:track:ID".
    static func spotifyURI(fromLinkOrURI text: String) -> String? {
        if text.hasPrefix("spotify:") { return text }
        guard let url = URL(string: text), url.host?.contains("spotify.com") == true else { return nil }
        let pathParts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
        guard pathParts.count >= 2 else { return nil }
        return "spotify:\(pathParts[0]):\(pathParts[1])"
    }

    static var hasSpotifyWebAPIKeys: Bool {
        KeychainStore.read(.spotifyClientID) != nil && KeychainStore.read(.spotifyClientSecret) != nil
    }

    /// Client-credentials search: finds the best playlist, album or track URI.
    private func searchSpotifyForURI(query: String) async -> String? {
        guard let accessToken = await spotifyAccessToken() else { return nil }

        let lowercasedQuery = query.lowercased()
        let preferredType: String
        if lowercasedQuery.contains("playlist") {
            preferredType = "playlist"
        } else if lowercasedQuery.contains("album") {
            preferredType = "album"
        } else {
            preferredType = "track"
        }
        let cleanedQuery = query
            .replacingOccurrences(of: "playlist", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "album", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: cleanedQuery.isEmpty ? query : cleanedQuery),
            URLQueryItem(name: "type", value: preferredType),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let searchURL = components.url else { return nil }
        var request = URLRequest(url: searchURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        guard let searchResponse = try? await session.data(for: request),
              (searchResponse.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: searchResponse.0) as? [String: Any],
              let section = json["\(preferredType)s"] as? [String: Any],
              let items = section["items"] as? [Any],
              let firstItem = items.compactMap({ $0 as? [String: Any] }).first,
              let uri = firstItem["uri"] as? String else {
            return nil
        }
        return uri
    }

    private func spotifyAccessToken() async -> String? {
        if let cachedSpotifyAccessToken, Date() < cachedSpotifyAccessTokenExpiryDate {
            return cachedSpotifyAccessToken
        }
        guard let clientID = KeychainStore.read(.spotifyClientID),
              let clientSecret = KeychainStore.read(.spotifyClientSecret),
              let tokenURL = URL(string: "https://accounts.spotify.com/api/token") else { return nil }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        let basicCredentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basicCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        guard let tokenResponse = try? await session.data(for: request),
              (tokenResponse.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: tokenResponse.0) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            return nil
        }
        let expiresInSeconds = (json["expires_in"] as? Double) ?? 3600
        cachedSpotifyAccessToken = accessToken
        cachedSpotifyAccessTokenExpiryDate = Date().addingTimeInterval(expiresInSeconds - 60)
        return accessToken
    }

    // MARK: - Apps, links, volume

    private func openApplication(named applicationName: String) -> MacActionResult {
        let description = "open_app \(applicationName)"
        guard !applicationName.isEmpty else {
            return MacActionResult(actionDescription: description, succeeded: false, detail: "no app name")
        }
        // `open -a` finds apps by display name the same way Spotlight does.
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", applicationName]
        do {
            try openProcess.run()
            openProcess.waitUntilExit()
            let succeeded = openProcess.terminationStatus == 0
            return MacActionResult(actionDescription: description, succeeded: succeeded,
                                   detail: succeeded ? nil : "couldn't find an app called \(applicationName)")
        } catch {
            return MacActionResult(actionDescription: description, succeeded: false, detail: error.localizedDescription)
        }
    }

    private func openURL(_ urlText: String) -> MacActionResult {
        let description = "open_url \(urlText)"
        var normalizedURLText = urlText
        if !normalizedURLText.contains("://") {
            normalizedURLText = "https://" + normalizedURLText
        }
        guard let url = URL(string: normalizedURLText) else {
            return MacActionResult(actionDescription: description, succeeded: false, detail: "bad link")
        }
        let opened = NSWorkspace.shared.open(url)
        return MacActionResult(actionDescription: description, succeeded: opened, detail: nil)
    }

    private func setOutputVolume(_ volumeText: String) -> MacActionResult {
        let digits = volumeText.filter(\.isNumber)
        guard let requestedVolume = Int(digits) else {
            return MacActionResult(actionDescription: "volume \(volumeText)", succeeded: false, detail: "no number")
        }
        let clampedVolume = max(0, min(100, requestedVolume))
        return runAppleScript("set volume output volume \(clampedVolume)", description: "volume \(clampedVolume)")
    }

    // MARK: - Typing

    /// Types text into whatever app is in front, using synthetic key events
    /// (needs the Accessibility permission Orchestra already asks for).
    private func typeTextIntoFrontmostApp(_ textToType: String) -> MacActionResult {
        let description = "type (\(textToType.count) characters)"
        guard !textToType.isEmpty else {
            return MacActionResult(actionDescription: description, succeeded: false, detail: "nothing to type")
        }
        if textToType.contains("\n") && ScreenControl.returnKeyWouldLikelySend() {
            return MacActionResult(actionDescription: description, succeeded: false,
                                   detail: "a new line there would send the message, so type it without pressing return")
        }
        ScreenControl.typeText(textToType)
        return MacActionResult(actionDescription: description, succeeded: true, detail: nil)
    }

    /// Code-level safety gate for key presses: send shortcuts never run, and
    /// return doesn't run where it would send a message.
    static func keyPressBlockReason(_ keyCombinationText: String) -> String? {
        if ScreenControl.isSendShortcut(keyCombinationText) {
            return "that shortcut sends or submits, so i'll leave it to you"
        }
        if ScreenControl.isPlainReturn(keyCombinationText) && ScreenControl.returnKeyWouldLikelySend() {
            return "pressing return there would send the message, so that last step is yours"
        }
        return nil
    }

    // MARK: - AppleScript

    private func runAppleScript(_ source: String, description: String) -> MacActionResult {
        guard let appleScript = NSAppleScript(source: source) else {
            return MacActionResult(actionDescription: description, succeeded: false, detail: "bad script")
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "applescript error"
            return MacActionResult(actionDescription: description, succeeded: false, detail: message)
        }
        return MacActionResult(actionDescription: description, succeeded: true, detail: nil)
    }
}

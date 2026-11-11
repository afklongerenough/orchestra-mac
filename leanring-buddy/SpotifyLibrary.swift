//
//  SpotifyLibrary.swift
//  leanring-buddy
//
//  Picks the right song when a name is ambiguous ("play stay high"), using
//  the user's own listening:
//    • Local history: while Spotify runs on this Mac, the current track is
//      noted every 20 s into ~/Orchestra/spotify-history.json (no setup).
//    • Spotify account (optional, "Connect Spotify account" in the menu):
//      recently played and top tracks, through Spotify's PKCE sign-in with
//      the user's own client id. Needs the redirect URI below added to that
//      app in the Spotify developer dashboard.
//  Search results are ranked by title match, artist match, how often and how
//  recently the user played that song/artist, then popularity.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct SpotifyTrackCandidate {
    let uri: String
    let name: String
    let artistNames: [String]
    let popularity: Int
}

struct SpotifyPlayedTrack: Codable {
    let uri: String
    let name: String
    let artistName: String
    let playedAt: Date
}

@MainActor
final class SpotifyLibrary {
    static let shared = SpotifyLibrary()

    static let accountRedirectURIText = "http://127.0.0.1:43821/callback"
    private static let accountRedirectPort: NWEndpoint.Port = 43821

    private let historyFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Orchestra", isDirectory: true)
        .appendingPathComponent("spotify-history.json")
    private let maximumHistoryEntryCount = 3000
    private var playedTracks: [SpotifyPlayedTrack] = []
    private var lastRecordedTrackURI: String?
    private var historyRecorderTimer: Timer?

    private var accountTracks: [SpotifyPlayedTrack] = []
    private var accountTracksFetchedDate = Date.distantPast
    private var cachedUserAccessToken: String?
    private var cachedUserAccessTokenExpiryDate = Date.distantPast
    private var signInListener: NWListener?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    var isAccountConnected: Bool { KeychainStore.read(.spotifyRefreshToken) != nil }

    // MARK: - Local listening history

    func startRecordingLocalHistory() {
        guard historyRecorderTimer == nil else { return }
        loadHistoryFile()
        historyRecorderTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordCurrentlyPlayingTrack() }
        }
    }

    private func recordCurrentlyPlayingTrack() {
        // Only ask Spotify if it's already running (an Apple Event would launch it).
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else { return }
        guard let nowPlaying = Self.currentlyPlayingTrack(onlyWhilePlaying: true),
              nowPlaying.uri != lastRecordedTrackURI else { return }
        lastRecordedTrackURI = nowPlaying.uri
        playedTracks.append(nowPlaying)
        if playedTracks.count > maximumHistoryEntryCount {
            playedTracks.removeFirst(playedTracks.count - maximumHistoryEntryCount)
        }
        saveHistoryFile()
    }

    /// What Spotify on this Mac is on right now (nil if it isn't running/playing).
    static func currentlyPlayingTrack(onlyWhilePlaying: Bool) -> SpotifyPlayedTrack? {
        let scriptSource = """
        tell application "Spotify"
          if \(onlyWhilePlaying ? "player state is playing" : "true") then
            return (id of current track) & "\\n" & (name of current track) & "\\n" & (artist of current track)
          end if
          return ""
        end tell
        """
        guard let appleScript = NSAppleScript(source: scriptSource) else { return nil }
        var errorInfo: NSDictionary?
        let resultText = appleScript.executeAndReturnError(&errorInfo).stringValue ?? ""
        let lines = resultText.components(separatedBy: "\n")
        guard errorInfo == nil, lines.count >= 3, lines[0].hasPrefix("spotify:track:") else { return nil }
        return SpotifyPlayedTrack(uri: lines[0], name: lines[1], artistName: lines[2], playedAt: Date())
    }

    private func loadHistoryFile() {
        guard let historyData = try? Data(contentsOf: historyFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        playedTracks = (try? decoder.decode([SpotifyPlayedTrack].self, from: historyData)) ?? []
        lastRecordedTrackURI = playedTracks.last?.uri
    }

    private func saveHistoryFile() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let historyData = try? encoder.encode(playedTracks) else { return }
        try? FileManager.default.createDirectory(at: historyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? historyData.write(to: historyFileURL, options: .atomic)
    }

    // MARK: - Ranking

    /// Picks the best search result for what the user asked, using their history.
    func bestCandidate(from candidates: [SpotifyTrackCandidate],
                       requestedTitle: String,
                       requestedArtist: String?) async -> (candidate: SpotifyTrackCandidate, isTitleMatch: Bool)? {
        await refreshAccountTracksIfStale()
        let allHistory = playedTracks + accountTracks
        let normalizedRequestedTitle = Self.normalizedSongTitle(requestedTitle)
        let normalizedRequestedArtist = requestedArtist.map(Self.normalizedText)

        var playCountByTrackURI: [String: Int] = [:]
        var lastPlayedByTrackURI: [String: Date] = [:]
        var playCountByArtist: [String: Int] = [:]
        for playedTrack in allHistory {
            playCountByTrackURI[playedTrack.uri, default: 0] += 1
            lastPlayedByTrackURI[playedTrack.uri] = max(lastPlayedByTrackURI[playedTrack.uri] ?? .distantPast, playedTrack.playedAt)
            for artistName in playedTrack.artistName.components(separatedBy: ", ") {
                playCountByArtist[Self.normalizedText(artistName), default: 0] += 1
            }
        }

        var bestScoredCandidate: (candidate: SpotifyTrackCandidate, score: Double, isTitleMatch: Bool)?
        for candidate in candidates {
            let normalizedCandidateTitle = Self.normalizedSongTitle(candidate.name)
            let isExactTitle = normalizedCandidateTitle == normalizedRequestedTitle
            let isPartialTitle = !isExactTitle && !normalizedRequestedTitle.isEmpty
                && (normalizedCandidateTitle.contains(normalizedRequestedTitle) || normalizedRequestedTitle.contains(normalizedCandidateTitle))
            var score = isExactTitle ? 100.0 : (isPartialTitle ? 40.0 : 0.0)

            let normalizedCandidateArtists = candidate.artistNames.map(Self.normalizedText)
            if let normalizedRequestedArtist, !normalizedRequestedArtist.isEmpty {
                if normalizedCandidateArtists.contains(where: { $0 == normalizedRequestedArtist || $0.contains(normalizedRequestedArtist) || normalizedRequestedArtist.contains($0) }) {
                    score += 80
                }
            }
            // The user's own listening: this exact song, then their artists.
            let trackPlayCount = playCountByTrackURI[candidate.uri] ?? 0
            if trackPlayCount > 0 {
                score += 30 + min(30, Double(trackPlayCount) * 3)
                if let lastPlayedDate = lastPlayedByTrackURI[candidate.uri] {
                    let daysSinceLastPlay = Date().timeIntervalSince(lastPlayedDate) / 86_400
                    score += max(0, 20 - daysSinceLastPlay)
                }
            }
            let artistPlayCount = normalizedCandidateArtists.map { playCountByArtist[$0] ?? 0 }.max() ?? 0
            score += min(35, Double(artistPlayCount) * 1.5)
            score += Double(candidate.popularity) / 10

            if bestScoredCandidate == nil || score > bestScoredCandidate!.score {
                bestScoredCandidate = (candidate, score, isExactTitle || isPartialTitle)
            }
        }
        return bestScoredCandidate.map { ($0.candidate, $0.isTitleMatch) }
    }

    /// "Stay High (feat. X) - Remastered" → "stay high"
    static func normalizedSongTitle(_ songTitle: String) -> String {
        var title = songTitle.lowercased()
        title = title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        return normalizedText(title)
    }

    static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Spotify account (optional)

    private func refreshAccountTracksIfStale() async {
        guard isAccountConnected, Date().timeIntervalSince(accountTracksFetchedDate) > 15 * 60 else { return }
        guard let userAccessToken = await userAccessToken() else { return }
        var fetchedTracks: [SpotifyPlayedTrack] = []

        if let recentlyPlayedJSON = await getJSON("https://api.spotify.com/v1/me/player/recently-played?limit=50", accessToken: userAccessToken),
           let items = recentlyPlayedJSON["items"] as? [[String: Any]] {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for item in items {
                guard let track = item["track"] as? [String: Any], let playedTrack = Self.playedTrack(fromTrackJSON: track,
                      playedAt: (item["played_at"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()) else { continue }
                fetchedTracks.append(playedTrack)
            }
        }
        // Top tracks count as "played often" (dated a month back so recent plays still win).
        for timeRange in ["short_term", "medium_term"] {
            if let topTracksJSON = await getJSON("https://api.spotify.com/v1/me/top/tracks?limit=50&time_range=\(timeRange)", accessToken: userAccessToken),
               let items = topTracksJSON["items"] as? [[String: Any]] {
                for track in items {
                    if let playedTrack = Self.playedTrack(fromTrackJSON: track, playedAt: Date().addingTimeInterval(-30 * 86_400)) {
                        fetchedTracks.append(playedTrack)
                    }
                }
            }
        }
        accountTracks = fetchedTracks
        accountTracksFetchedDate = Date()
    }

    private static func playedTrack(fromTrackJSON track: [String: Any], playedAt: Date) -> SpotifyPlayedTrack? {
        guard let uri = track["uri"] as? String, let name = track["name"] as? String else { return nil }
        let artistNames = (track["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        return SpotifyPlayedTrack(uri: uri, name: name, artistName: artistNames.joined(separator: ", "), playedAt: playedAt)
    }

    private func getJSON(_ urlText: String, accessToken: String) async -> [String: Any]? {
        guard let url = URL(string: urlText) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (responseData, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    private func userAccessToken() async -> String? {
        if let cachedUserAccessToken, Date() < cachedUserAccessTokenExpiryDate { return cachedUserAccessToken }
        guard let refreshToken = KeychainStore.read(.spotifyRefreshToken),
              let clientID = KeychainStore.read(.spotifyClientID) else { return nil }
        let tokenJSON = await postTokenRequest(formFields: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID
        ])
        guard let tokenJSON, let accessToken = tokenJSON["access_token"] as? String else { return nil }
        // Spotify may rotate the refresh token.
        if let rotatedRefreshToken = tokenJSON["refresh_token"] as? String {
            KeychainStore.write(rotatedRefreshToken, for: .spotifyRefreshToken)
        }
        cachedUserAccessToken = accessToken
        cachedUserAccessTokenExpiryDate = Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60)
        return accessToken
    }

    private func postTokenRequest(formFields: [String: String]) async -> [String: Any]? {
        guard let tokenURL = URL(string: "https://accounts.spotify.com/api/token") else { return nil }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = formFields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((bodyComponents.percentEncodedQuery ?? "").utf8)
        guard let (responseData, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    /// Opens Spotify's sign-in page; a tiny local listener catches the reply.
    /// Returns a short status for the menu.
    func connectAccount() async -> String {
        guard let clientID = KeychainStore.read(.spotifyClientID) else {
            return "save your spotify client id under connections first"
        }
        let codeVerifier = Self.randomURLSafeString(byteCount: 48)
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let expectedState = Self.randomURLSafeString(byteCount: 16)

        var authorizeComponents = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorizeComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.accountRedirectURIText),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "scope", value: "user-read-recently-played user-top-read")
        ]
        guard let authorizeURL = authorizeComponents.url else { return "couldn't build the sign-in link" }

        guard let callbackQueryItems = await waitForSignInCallback(openingAuthorizeURL: authorizeURL) else {
            return "spotify sign-in didn't finish (check the redirect uri \(Self.accountRedirectURIText) is added to your spotify app)"
        }
        guard callbackQueryItems["state"] == expectedState, let authorizationCode = callbackQueryItems["code"] else {
            return "spotify sign-in was cancelled"
        }
        let tokenJSON = await postTokenRequest(formFields: [
            "grant_type": "authorization_code", "code": authorizationCode,
            "redirect_uri": Self.accountRedirectURIText, "client_id": clientID, "code_verifier": codeVerifier
        ])
        guard let tokenJSON, let refreshToken = tokenJSON["refresh_token"] as? String else {
            return "spotify didn't accept the sign-in"
        }
        KeychainStore.write(refreshToken, for: .spotifyRefreshToken)
        cachedUserAccessToken = tokenJSON["access_token"] as? String
        cachedUserAccessTokenExpiryDate = Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60)
        accountTracksFetchedDate = .distantPast
        return "spotify account connected"
    }

    func disconnectAccount() {
        KeychainStore.delete(.spotifyRefreshToken)
        cachedUserAccessToken = nil
        accountTracks = []
    }

    /// Listens on 127.0.0.1:43821 for one /callback request (2-minute limit).
    private func waitForSignInCallback(openingAuthorizeURL authorizeURL: URL) async -> [String: String]? {
        signInListener?.cancel()
        let listenerParameters = NWParameters.tcp
        // Loopback only: nothing outside this Mac can reach the listener.
        listenerParameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: listenerParameters, on: Self.accountRedirectPort) else { return nil }
        signInListener = listener

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: String]?, Never>) in
            var hasResumed = false
            let resumeOnce: ([String: String]?) -> Void = { queryItems in
                DispatchQueue.main.async {
                    guard !hasResumed else { return }
                    hasResumed = true
                    listener.cancel()
                    continuation.resume(returning: queryItems)
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { requestData, _, _, _ in
                    let requestText = requestData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let requestLine = requestText.components(separatedBy: "\r\n").first ?? ""
                    let requestPath = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    guard requestPath.hasPrefix("/callback") else {
                        connection.cancel()
                        return
                    }
                    var queryItems: [String: String] = [:]
                    for queryItem in URLComponents(string: "http://127.0.0.1" + requestPath)?.queryItems ?? [] {
                        queryItems[queryItem.name] = queryItem.value
                    }
                    let pageText = queryItems["code"] != nil
                        ? "Spotify is connected to Orchestra. You can close this tab."
                        : "Spotify sign-in was cancelled. You can close this tab."
                    let responseText = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:-apple-system;padding:40px\">\(pageText)</body></html>"
                    connection.send(content: Data(responseText.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        resumeOnce(queryItems)
                    })
                }
            }
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    DispatchQueue.main.async { NSWorkspace.shared.open(authorizeURL) }
                case .failed:
                    resumeOnce(nil)
                default:
                    break
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { resumeOnce(nil) }
        }
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var randomBytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &randomBytes)
        return Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

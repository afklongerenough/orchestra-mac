//
//  GoogleConnector.swift
//  leanring-buddy
//
//  Gmail, Google Calendar and Google Drive as a built-in connector called
//  "google". The user creates their own OAuth client (type "Desktop app") in
//  Google Cloud Console, pastes its client id and secret under Connections,
//  and signs in once in the browser (loopback redirect, PKCE).
//
//  Deliberately read-only: the scopes asked for are gmail.readonly,
//  calendar.readonly and drive.readonly, and every tool below only reads.
//  Sending mail, changing events or uploading files is not implemented here —
//  those stay with the user (or a Hermes job they confirm).
//
//  Tools (same shape as MCP connectors, so the voice models use them the
//  same way): gmail_search, gmail_read, calendar_events, drive_search,
//  drive_read.
//

import AppKit
import Combine
import Foundation

@MainActor
final class GoogleConnectorManager: ObservableObject {
    static let shared = GoogleConnectorManager()

    static let connectorIdentifier = "google"
    private static let requestedScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/drive.readonly"
    ].joined(separator: " ")

    @Published private(set) var isSigningIn = false
    @Published private(set) var statusText = ""

    private var cachedAccessToken: String?
    private var cachedAccessTokenExpiryDate = Date.distantPast

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private init() {}

    var isConnected: Bool { KeychainStore.read(.googleRefreshToken) != nil }
    var hasClientCredentials: Bool {
        KeychainStore.read(.googleClientID) != nil && KeychainStore.read(.googleClientSecret) != nil
    }

    // MARK: - Sign-in

    /// Opens Google's consent page; the loopback listener catches the code.
    func connectAccount() async -> String {
        guard !isSigningIn else { return "a sign-in is already open in the browser" }
        guard let clientID = KeychainStore.read(.googleClientID),
              let clientSecret = KeychainStore.read(.googleClientSecret) else {
            return "paste your google client id and secret first (Google Cloud Console → APIs & Services → Credentials → OAuth client, type Desktop app)"
        }
        isSigningIn = true
        defer { isSigningIn = false }

        let codeVerifier = ConnectorOAuthFlow.randomURLSafeString(byteCount: 48)
        let expectedState = ConnectorOAuthFlow.randomURLSafeString(byteCount: 16)
        var authorizeComponents = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorizeComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthLoopbackListener.redirectURIText),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.requestedScopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "code_challenge", value: ConnectorOAuthFlow.codeChallenge(fromVerifier: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizeURL = authorizeComponents.url else { return "couldn't build the sign-in link" }
        guard let callbackQueryItems = await OAuthLoopbackListener.waitForCallback(
            openingAuthorizeURL: authorizeURL,
            successPageText: "Google is connected to Orchestra (read-only). You can close this tab.",
            failurePageText: "Google sign-in was cancelled. You can close this tab.") else {
            return "google sign-in didn't finish in time"
        }
        if let callbackError = callbackQueryItems["error"] {
            return "google sign-in was refused: \(callbackError)"
        }
        guard callbackQueryItems["state"] == expectedState, let authorizationCode = callbackQueryItems["code"] else {
            return "google sign-in was cancelled"
        }
        do {
            let tokenJSON = try await ConnectorOAuthFlow.requestTokens(tokenEndpoint: "https://oauth2.googleapis.com/token", formFields: [
                "grant_type": "authorization_code",
                "code": authorizationCode,
                "redirect_uri": OAuthLoopbackListener.redirectURIText,
                "client_id": clientID,
                "client_secret": clientSecret,
                "code_verifier": codeVerifier
            ])
            guard let refreshToken = tokenJSON["refresh_token"] as? String else {
                return "google didn't return a refresh token; try connecting again"
            }
            KeychainStore.write(refreshToken, for: .googleRefreshToken)
            cachedAccessToken = tokenJSON["access_token"] as? String
            cachedAccessTokenExpiryDate = Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60)
            statusText = "connected (read-only)"
            OrchestraLog.write("🔐 Google connector: signed in (read-only scopes)")
            return "google connected — gmail, calendar and drive are readable by voice (read-only)"
        } catch {
            return error.localizedDescription
        }
    }

    func disconnectAccount() {
        KeychainStore.delete(.googleRefreshToken)
        cachedAccessToken = nil
        cachedAccessTokenExpiryDate = .distantPast
        statusText = "disconnected"
    }

    private func accessToken() async -> String? {
        if let cachedAccessToken, Date() < cachedAccessTokenExpiryDate { return cachedAccessToken }
        guard let refreshToken = KeychainStore.read(.googleRefreshToken),
              let clientID = KeychainStore.read(.googleClientID),
              let clientSecret = KeychainStore.read(.googleClientSecret) else { return nil }
        do {
            let tokenJSON = try await ConnectorOAuthFlow.requestTokens(tokenEndpoint: "https://oauth2.googleapis.com/token", formFields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
                "client_secret": clientSecret
            ])
            guard let accessToken = tokenJSON["access_token"] as? String else { return nil }
            if let rotatedRefreshToken = tokenJSON["refresh_token"] as? String {
                KeychainStore.write(rotatedRefreshToken, for: .googleRefreshToken)
            }
            cachedAccessToken = accessToken
            cachedAccessTokenExpiryDate = Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60)
            return accessToken
        } catch {
            OrchestraLog.write("🔐 Google connector: token refresh failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - For the models (same shape as MCP connectors)

    /// The tool list for system prompts. All tools are read-only, so none of
    /// them needs the parked "yes" flow.
    var toolCatalogForPrompt: String {
        guard isConnected else { return "" }
        return """
        connector "google" (the user's gmail, google calendar and google drive — read-only):
        - gmail_search(query, max_results): search mail, e.g. {"query": "from:bank newer_than:7d"}. returns ids, senders, subjects, snippets.
        - gmail_read(message_id): the full text of one email (use an id from gmail_search).
        - calendar_events(time_min, time_max): events between two ISO dates like 2026-05-01T00:00:00 (local time). defaults to the next 7 days.
        - drive_search(query, max_results): find files by name or content, e.g. {"query": "essay draft"}.
        - drive_read(file_id): the text of a google doc or text file (use an id from drive_search).
        """
    }

    /// Runs one read-only tool. Returns text for the model (or an error line).
    func runTool(toolName: String, argumentsJSONText: String) async -> String {
        guard isConnected else { return "the google connector isn't connected; the user can sign in under connections in the orchestra menu" }
        guard let accessToken = await accessToken() else {
            return "the google sign-in expired; ask the user to connect google again under connections"
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSONText.utf8))) as? [String: Any] ?? [:]
        do {
            switch toolName {
            case "gmail_search":
                return try await gmailSearch(query: arguments["query"] as? String ?? "",
                                             maxResults: arguments["max_results"] as? Int ?? 6,
                                             accessToken: accessToken)
            case "gmail_read":
                guard let messageIdentifier = arguments["message_id"] as? String, !messageIdentifier.isEmpty else {
                    return "gmail_read needs a message_id from gmail_search"
                }
                return try await gmailRead(messageIdentifier: messageIdentifier, accessToken: accessToken)
            case "calendar_events":
                return try await calendarEvents(timeMinText: arguments["time_min"] as? String,
                                                timeMaxText: arguments["time_max"] as? String,
                                                accessToken: accessToken)
            case "drive_search":
                return try await driveSearch(query: arguments["query"] as? String ?? "",
                                             maxResults: arguments["max_results"] as? Int ?? 8,
                                             accessToken: accessToken)
            case "drive_read":
                guard let fileIdentifier = arguments["file_id"] as? String, !fileIdentifier.isEmpty else {
                    return "drive_read needs a file_id from drive_search"
                }
                return try await driveRead(fileIdentifier: fileIdentifier, accessToken: accessToken)
            default:
                return "unknown google tool \(toolName). available: gmail_search, gmail_read, calendar_events, drive_search, drive_read"
            }
        } catch {
            OrchestraLog.write("🔐 Google \(toolName) failed: \(error.localizedDescription)")
            return "failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Gmail (read-only)

    private func gmailSearch(query: String, maxResults: Int, accessToken: String) async throws -> String {
        var listComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(max(1, min(maxResults, 10))))
        ]
        guard let listJSON = try await getAuthorizedJSON(listComponents.url, accessToken: accessToken),
              let messageStubs = listJSON["messages"] as? [[String: Any]], !messageStubs.isEmpty else {
            return "no emails matched \"\(query)\""
        }
        var resultLines: [String] = []
        for messageStub in messageStubs.prefix(6) {
            guard let messageIdentifier = messageStub["id"] as? String else { continue }
            var messageComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageIdentifier)")!
            messageComponents.queryItems = [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Subject"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "Date")
            ]
            guard let messageJSON = try await getAuthorizedJSON(messageComponents.url, accessToken: accessToken) else { continue }
            let headers = (messageJSON["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
            func headerValue(_ headerName: String) -> String {
                (headers.first { ($0["name"] as? String)?.lowercased() == headerName.lowercased() }?["value"] as? String) ?? ""
            }
            let snippet = (messageJSON["snippet"] as? String) ?? ""
            resultLines.append("id: \(messageIdentifier)\nfrom: \(headerValue("From"))\nsubject: \(headerValue("Subject"))\ndate: \(headerValue("Date"))\nsnippet: \(snippet)")
        }
        return resultLines.isEmpty ? "no readable emails matched" : resultLines.joined(separator: "\n---\n")
    }

    private func gmailRead(messageIdentifier: String, accessToken: String) async throws -> String {
        var messageComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageIdentifier)")!
        messageComponents.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let messageJSON = try await getAuthorizedJSON(messageComponents.url, accessToken: accessToken) else {
            return "couldn't read that email"
        }
        let payload = messageJSON["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        let subject = (headers.first { ($0["name"] as? String) == "Subject" }?["value"] as? String) ?? "(no subject)"
        let sender = (headers.first { ($0["name"] as? String) == "From" }?["value"] as? String) ?? ""
        let bodyText = Self.plainText(fromGmailPayload: payload)
        let trimmedBody = bodyText.isEmpty ? ((messageJSON["snippet"] as? String) ?? "") : bodyText
        return "subject: \(subject)\nfrom: \(sender)\n\n\(String(trimmedBody.prefix(6000)))"
    }

    /// Walks the MIME parts for text/plain (falling back to stripped html).
    private static func plainText(fromGmailPayload payload: [String: Any]) -> String {
        let mimeType = (payload["mimeType"] as? String) ?? ""
        if mimeType == "text/plain", let bodyData = decodedGmailBodyData(payload["body"] as? [String: Any]) {
            return String(data: bodyData, encoding: .utf8) ?? ""
        }
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts where (part["mimeType"] as? String) == "text/plain" {
                if let bodyData = decodedGmailBodyData(part["body"] as? [String: Any]),
                   let partText = String(data: bodyData, encoding: .utf8), !partText.isEmpty {
                    return partText
                }
            }
            for part in parts {
                let nestedText = plainText(fromGmailPayload: part)
                if !nestedText.isEmpty { return nestedText }
            }
            for part in parts where (part["mimeType"] as? String) == "text/html" {
                if let bodyData = decodedGmailBodyData(part["body"] as? [String: Any]),
                   let htmlText = String(data: bodyData, encoding: .utf8) {
                    let strippedText = htmlText
                        .replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !strippedText.isEmpty { return strippedText }
                }
            }
        }
        if mimeType == "text/html", let bodyData = decodedGmailBodyData(payload["body"] as? [String: Any]),
           let htmlText = String(data: bodyData, encoding: .utf8) {
            return htmlText
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func decodedGmailBodyData(_ body: [String: Any]?) -> Data? {
        guard let base64URLText = body?["data"] as? String else { return nil }
        let base64Text = base64URLText
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedBase64Text = base64Text.padding(toLength: ((base64Text.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        return Data(base64Encoded: paddedBase64Text)
    }

    // MARK: - Calendar (read-only)

    private func calendarEvents(timeMinText: String?, timeMaxText: String?, accessToken: String) async throws -> String {
        let timeMinDate = timeMinText.flatMap(Self.parseGoogleDate) ?? Date()
        let timeMaxDate = timeMaxText.flatMap(Self.parseGoogleDate) ?? timeMinDate.addingTimeInterval(7 * 86_400)
        let isoFormatter = ISO8601DateFormatter()
        var eventsComponents = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        eventsComponents.queryItems = [
            URLQueryItem(name: "timeMin", value: isoFormatter.string(from: timeMinDate)),
            URLQueryItem(name: "timeMax", value: isoFormatter.string(from: timeMaxDate)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "25")
        ]
        guard let eventsJSON = try await getAuthorizedJSON(eventsComponents.url, accessToken: accessToken),
              let eventItems = eventsJSON["items"] as? [[String: Any]], !eventItems.isEmpty else {
            return "no google calendar events in that range"
        }
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEE MMM d, HH:mm"
        var eventLines: [String] = []
        for eventItem in eventItems {
            let summary = (eventItem["summary"] as? String) ?? "(busy)"
            let startText = ((eventItem["start"] as? [String: Any])?["dateTime"] as? String)
                ?? ((eventItem["start"] as? [String: Any])?["date"] as? String) ?? ""
            let endText = ((eventItem["end"] as? [String: Any])?["dateTime"] as? String) ?? ""
            let startDate = Self.parseGoogleDate(startText)
            let endDate = Self.parseGoogleDate(endText)
            let whenText = startDate.map { displayFormatter.string(from: $0) } ?? startText
            let untilText = endDate.map { "–" + displayFormatter.string(from: $0) } ?? ""
            let location = (eventItem["location"] as? String).map { " @ \($0)" } ?? ""
            eventLines.append("\(whenText)\(untilText): \(summary)\(location)")
        }
        return eventLines.joined(separator: "\n")
    }

    /// Accepts ISO timestamps with or without a zone, and plain dates.
    static func parseGoogleDate(_ dateText: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let parsedDate = isoFormatter.date(from: dateText) { return parsedDate }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsedDate = isoFormatter.date(from: dateText) { return parsedDate }
        let localFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        for dateFormat in localFormats {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = dateFormat
            if let parsedDate = dateFormatter.date(from: dateText) { return parsedDate }
        }
        return nil
    }

    // MARK: - Drive (read-only)

    private func driveSearch(query: String, maxResults: Int, accessToken: String) async throws -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Plain words become a name-or-content search; a real Drive query
        // (with operators like "contains" or "mimeType") is passed through.
        let driveQuery: String
        if trimmedQuery.contains("contains") || trimmedQuery.contains("mimeType") || trimmedQuery.contains(" and ") {
            driveQuery = trimmedQuery
        } else {
            let escapedQuery = trimmedQuery.replacingOccurrences(of: "'", with: "\\'")
            driveQuery = "(name contains '\(escapedQuery)' or fullText contains '\(escapedQuery)')"
        }
        var searchComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: driveQuery + " and trashed = false"),
            URLQueryItem(name: "pageSize", value: String(max(1, min(maxResults, 15)))),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,modifiedTime)"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc")
        ]
        guard let searchJSON = try await getAuthorizedJSON(searchComponents.url, accessToken: accessToken),
              let fileItems = searchJSON["files"] as? [[String: Any]], !fileItems.isEmpty else {
            return "no drive files matched \"\(query)\""
        }
        let fileLines = fileItems.map { fileItem in
            "id: \(fileItem["id"] as? String ?? "") | \(fileItem["name"] as? String ?? "") | \(fileItem["mimeType"] as? String ?? "") | modified \(fileItem["modifiedTime"] as? String ?? "")"
        }
        return fileLines.joined(separator: "\n")
    }

    private func driveRead(fileIdentifier: String, accessToken: String) async throws -> String {
        var metadataComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileIdentifier)")!
        metadataComponents.queryItems = [URLQueryItem(name: "fields", value: "id,name,mimeType,size")]
        guard let metadataJSON = try await getAuthorizedJSON(metadataComponents.url, accessToken: accessToken) else {
            return "couldn't find that drive file"
        }
        let mimeType = (metadataJSON["mimeType"] as? String) ?? ""
        let fileName = (metadataJSON["name"] as? String) ?? fileIdentifier
        if mimeType == "application/vnd.google-apps.document" {
            var exportComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileIdentifier)/export")!
            exportComponents.queryItems = [URLQueryItem(name: "mimeType", value: "text/plain")]
            let exportText = try await getAuthorizedText(exportComponents.url, accessToken: accessToken)
            return "\(fileName):\n\(String(exportText.prefix(6000)))"
        }
        if mimeType.hasPrefix("text/") || mimeType == "application/json" {
            var mediaComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileIdentifier)")!
            mediaComponents.queryItems = [URLQueryItem(name: "alt", value: "media")]
            let fileText = try await getAuthorizedText(mediaComponents.url, accessToken: accessToken)
            return "\(fileName):\n\(String(fileText.prefix(6000)))"
        }
        return "\(fileName) is a \(mimeType) file — orchestra can only read google docs and text files"
    }

    // MARK: - HTTP helpers

    private func getAuthorizedJSON(_ url: URL?, accessToken: String) async throws -> [String: Any]? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? ""
            OrchestraLog.write("🔐 Google API \(statusCode): \(errorBody.prefix(200))")
            if statusCode == 401 || statusCode == 403 {
                throw ConnectorOAuthError(message: "google refused the request (\(statusCode)); the sign-in may need to be redone, or the API isn't enabled in the user's google cloud project")
            }
            throw ConnectorOAuthError(message: "google api error \(statusCode)")
        }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    private func getAuthorizedText(_ url: URL?, accessToken: String) async throws -> String {
        guard let url else { return "" }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw ConnectorOAuthError(message: "google api error \(statusCode)")
        }
        return String(data: responseData, encoding: .utf8) ?? ""
    }
}

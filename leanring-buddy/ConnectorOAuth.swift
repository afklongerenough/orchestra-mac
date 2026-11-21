//
//  ConnectorOAuth.swift
//  leanring-buddy
//
//  "Sign in with…" for connectors: the OAuth 2.0 authorization-code flow with
//  PKCE that MCP servers like Notion's hosted server (mcp.notion.com) use.
//
//    1. discover the server's OAuth endpoints (RFC 9728 protected-resource
//       metadata → RFC 8414 authorization-server metadata),
//    2. register Orchestra as a public client (RFC 7591 dynamic registration),
//    3. open the sign-in page in the browser; a tiny loopback listener on
//       127.0.0.1:43822 catches the redirect (same idea as the Spotify sign-in),
//    4. exchange the code for tokens, keep the refresh token in the secrets
//       file, and hand fresh access tokens to MCPConnectorManager.
//
//  Nothing secret ships in the app; each user signs in to their own account.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

/// One /callback request on a loopback-only port (nothing outside this Mac
/// can reach it). Shared by the connector and Google sign-ins.
enum OAuthLoopbackListener {
    static let redirectURIText = "http://127.0.0.1:43822/callback"
    private static let redirectPort: NWEndpoint.Port = 43822

    /// Opens `authorizeURL` once the listener is ready; returns the callback's
    /// query items, or nil on timeout/failure (2-minute limit).
    static func waitForCallback(openingAuthorizeURL authorizeURL: URL,
                                successPageText: String,
                                failurePageText: String) async -> [String: String]? {
        let listenerParameters = NWParameters.tcp
        listenerParameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: listenerParameters, on: redirectPort) else { return nil }

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
                    let pageText = queryItems["code"] != nil ? successPageText : failurePageText
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
}

/// The OAuth endpoints one connector's server told us about.
struct ConnectorOAuthServerMetadata {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?
}

/// What we keep per connector so the next sign-in/refresh needs no discovery:
/// the registered client and the endpoints. Not secret (no tokens in here).
struct ConnectorOAuthClientRecord: Codable {
    let clientID: String
    var clientSecret: String?
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let issuer: String
    let resourceURLText: String
}

struct ConnectorOAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Discovery, registration and token requests. Pure networking — no UI state.
enum ConnectorOAuthFlow {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// Finds the authorization server for an MCP endpoint: first the
    /// protected-resource metadata (which names the authorization server),
    /// then that server's metadata. Falls back to well-known URLs on the
    /// MCP server's own origin.
    static func discoverServerMetadata(forServerURL serverURL: URL) async throws -> ConnectorOAuthServerMetadata {
        guard let scheme = serverURL.scheme, let host = serverURL.host else {
            throw ConnectorOAuthError(message: "bad server address")
        }
        let serverOrigin = "\(scheme)://\(host)" + (serverURL.port.map { ":\($0)" } ?? "")
        var candidateMetadataURLTexts: [String] = []

        // RFC 9728: well-known sits between the origin and the resource path.
        let resourcePath = serverURL.path.hasPrefix("/") ? serverURL.path : "/" + serverURL.path
        let protectedResourceMetadataURLTexts = [
            serverOrigin + "/.well-known/oauth-protected-resource" + resourcePath,
            serverOrigin + "/.well-known/oauth-protected-resource"
        ]
        for protectedResourceURLText in protectedResourceMetadataURLTexts {
            guard let protectedResourceJSON = await getJSON(protectedResourceURLText),
                  let authorizationServers = protectedResourceJSON["authorization_servers"] as? [String],
                  let authorizationServerIssuer = authorizationServers.first else { continue }
            let issuerOrigin = authorizationServerIssuer.hasSuffix("/")
                ? String(authorizationServerIssuer.dropLast()) : authorizationServerIssuer
            candidateMetadataURLTexts.append(issuerOrigin + "/.well-known/oauth-authorization-server")
            candidateMetadataURLTexts.append(issuerOrigin + "/.well-known/openid-configuration")
        }
        candidateMetadataURLTexts.append(serverOrigin + "/.well-known/oauth-authorization-server")
        candidateMetadataURLTexts.append(serverOrigin + "/.well-known/openid-configuration")

        for metadataURLText in candidateMetadataURLTexts {
            guard let metadataJSON = await getJSON(metadataURLText),
                  let authorizationEndpoint = metadataJSON["authorization_endpoint"] as? String,
                  let tokenEndpoint = metadataJSON["token_endpoint"] as? String else { continue }
            return ConnectorOAuthServerMetadata(
                issuer: (metadataJSON["issuer"] as? String) ?? serverOrigin,
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: metadataJSON["registration_endpoint"] as? String)
        }
        throw ConnectorOAuthError(message: "this server doesn't advertise a sign-in (OAuth) endpoint; it may only take a token")
    }

    /// RFC 7591 dynamic client registration: Orchestra registers itself as a
    /// public client (no secret) with the loopback redirect.
    static func registerClient(metadata: ConnectorOAuthServerMetadata) async throws -> ConnectorOAuthClientRecord {
        guard let registrationEndpoint = metadata.registrationEndpoint,
              let registrationURL = URL(string: registrationEndpoint) else {
            throw ConnectorOAuthError(message: "this server doesn't support automatic client registration; add its token instead")
        }
        var request = URLRequest(url: registrationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Orchestra",
            "redirect_uris": [OAuthLoopbackListener.redirectURIText],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ] as [String: Any])
        let (responseData, response) = try await session.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(statusCode),
              let registrationJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let clientID = registrationJSON["client_id"] as? String else {
            throw ConnectorOAuthError(message: "the server refused the client registration (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return ConnectorOAuthClientRecord(clientID: clientID,
                                          clientSecret: registrationJSON["client_secret"] as? String,
                                          authorizationEndpoint: metadata.authorizationEndpoint,
                                          tokenEndpoint: metadata.tokenEndpoint,
                                          issuer: metadata.issuer,
                                          resourceURLText: "")
    }

    /// Builds the sign-in link (PKCE S256 + state + the MCP resource binding).
    static func authorizationURL(clientRecord: ConnectorOAuthClientRecord,
                                 resourceURLText: String,
                                 codeChallenge: String,
                                 state: String) -> URL? {
        guard var authorizeComponents = URLComponents(string: clientRecord.authorizationEndpoint) else { return nil }
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientRecord.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthLoopbackListener.redirectURIText),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if !resourceURLText.isEmpty {
            queryItems.append(URLQueryItem(name: "resource", value: resourceURLText))
        }
        // Keep any query the endpoint itself carries.
        authorizeComponents.queryItems = (authorizeComponents.queryItems ?? []) + queryItems
        return authorizeComponents.url
    }

    /// Exchanges the authorization code (or refreshes) at the token endpoint.
    static func requestTokens(tokenEndpoint: String, formFields: [String: String]) async throws -> [String: Any] {
        guard let tokenURL = URL(string: tokenEndpoint) else {
            throw ConnectorOAuthError(message: "bad token endpoint")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = formFields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((bodyComponents.percentEncodedQuery ?? "").utf8)
        let (responseData, response) = try await session.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(statusCode),
              let tokenJSON = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              tokenJSON["access_token"] as? String != nil else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? ""
            OrchestraLog.write("🔐 OAuth token request refused (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(errorBody.prefix(200))")
            throw ConnectorOAuthError(message: "the sign-in server didn't accept the token request (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return tokenJSON
    }

    static func getJSON(_ urlText: String) async -> [String: Any]? {
        guard let url = URL(string: urlText) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (responseData, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        var randomBytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &randomBytes)
        return Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func codeChallenge(fromVerifier codeVerifier: String) -> String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Per-connector sign-in state: client records (UserDefaults), refresh tokens
/// (secrets file), cached access tokens (memory only).
@MainActor
final class ConnectorOAuthManager: ObservableObject {
    static let shared = ConnectorOAuthManager()

    /// The connector currently showing its browser sign-in, if any.
    @Published private(set) var signingInConnectorIdentifier: String?

    private static let clientRecordsDefaultsKey = "connectorOAuthClientRecords"
    private var clientRecordsByConnector: [String: ConnectorOAuthClientRecord] = [:]
    private var cachedAccessTokensByConnector: [String: (token: String, expiryDate: Date)] = [:]

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.clientRecordsDefaultsKey),
           let savedRecords = try? JSONDecoder().decode([String: ConnectorOAuthClientRecord].self, from: savedData) {
            clientRecordsByConnector = savedRecords
        }
    }

    func hasSession(connectorIdentifier: String) -> Bool {
        KeychainStore.readCustomSecret(named: "mcp-oauth-refresh-\(connectorIdentifier)") != nil
    }

    /// Full browser sign-in for one connector. Returns a short status line.
    func signIn(connectorIdentifier: String, serverURLText: String) async -> String {
        guard signingInConnectorIdentifier == nil else { return "another sign-in is already open in the browser" }
        guard let serverURL = URL(string: serverURLText) else { return "bad server address" }
        signingInConnectorIdentifier = connectorIdentifier
        defer { signingInConnectorIdentifier = nil }
        do {
            let metadata = try await ConnectorOAuthFlow.discoverServerMetadata(forServerURL: serverURL)
            var clientRecord: ConnectorOAuthClientRecord
            if let existingRecord = clientRecordsByConnector[connectorIdentifier],
               existingRecord.tokenEndpoint == metadata.tokenEndpoint {
                clientRecord = existingRecord
            } else {
                clientRecord = try await ConnectorOAuthFlow.registerClient(metadata: metadata)
            }
            clientRecord = ConnectorOAuthClientRecord(clientID: clientRecord.clientID,
                                                      clientSecret: clientRecord.clientSecret,
                                                      authorizationEndpoint: clientRecord.authorizationEndpoint,
                                                      tokenEndpoint: clientRecord.tokenEndpoint,
                                                      issuer: clientRecord.issuer,
                                                      resourceURLText: serverURL.absoluteString)

            let codeVerifier = ConnectorOAuthFlow.randomURLSafeString(byteCount: 48)
            let expectedState = ConnectorOAuthFlow.randomURLSafeString(byteCount: 16)
            guard let authorizeURL = ConnectorOAuthFlow.authorizationURL(
                clientRecord: clientRecord,
                resourceURLText: serverURL.absoluteString,
                codeChallenge: ConnectorOAuthFlow.codeChallenge(fromVerifier: codeVerifier),
                state: expectedState) else {
                return "couldn't build the sign-in link"
            }
            guard let callbackQueryItems = await OAuthLoopbackListener.waitForCallback(
                openingAuthorizeURL: authorizeURL,
                successPageText: "Connected to Orchestra. You can close this tab.",
                failurePageText: "Sign-in was cancelled. You can close this tab.") else {
                return "sign-in didn't finish in time (is another sign-in window open?)"
            }
            if let callbackError = callbackQueryItems["error"] {
                return "sign-in was refused: \(callbackError)"
            }
            guard callbackQueryItems["state"] == expectedState, let authorizationCode = callbackQueryItems["code"] else {
                return "sign-in was cancelled"
            }
            var tokenFormFields = [
                "grant_type": "authorization_code",
                "code": authorizationCode,
                "redirect_uri": OAuthLoopbackListener.redirectURIText,
                "client_id": clientRecord.clientID,
                "code_verifier": codeVerifier,
                "resource": serverURL.absoluteString
            ]
            if let clientSecret = clientRecord.clientSecret { tokenFormFields["client_secret"] = clientSecret }
            let tokenJSON = try await ConnectorOAuthFlow.requestTokens(tokenEndpoint: clientRecord.tokenEndpoint, formFields: tokenFormFields)
            guard let accessToken = tokenJSON["access_token"] as? String else { return "the server didn't return a token" }
            if let refreshToken = tokenJSON["refresh_token"] as? String {
                KeychainStore.writeCustomSecret(refreshToken, named: "mcp-oauth-refresh-\(connectorIdentifier)")
            }
            clientRecordsByConnector[connectorIdentifier] = clientRecord
            saveClientRecords()
            cachedAccessTokensByConnector[connectorIdentifier] = (
                token: accessToken,
                expiryDate: Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60))
            OrchestraLog.write("🔐 Connector \(connectorIdentifier): signed in with OAuth")
            return "signed in"
        } catch {
            return error.localizedDescription
        }
    }

    /// A usable access token, refreshed when it's close to expiry. Nil when
    /// the connector has no session (or the refresh token was revoked).
    func validAccessToken(connectorIdentifier: String) async -> String? {
        if let cachedToken = cachedAccessTokensByConnector[connectorIdentifier], Date() < cachedToken.expiryDate {
            return cachedToken.token
        }
        guard let refreshToken = KeychainStore.readCustomSecret(named: "mcp-oauth-refresh-\(connectorIdentifier)"),
              let clientRecord = clientRecordsByConnector[connectorIdentifier] else { return nil }
        var refreshFormFields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientRecord.clientID
        ]
        if let clientSecret = clientRecord.clientSecret { refreshFormFields["client_secret"] = clientSecret }
        if !clientRecord.resourceURLText.isEmpty { refreshFormFields["resource"] = clientRecord.resourceURLText }
        do {
            let tokenJSON = try await ConnectorOAuthFlow.requestTokens(tokenEndpoint: clientRecord.tokenEndpoint, formFields: refreshFormFields)
            guard let accessToken = tokenJSON["access_token"] as? String else { return nil }
            if let rotatedRefreshToken = tokenJSON["refresh_token"] as? String {
                KeychainStore.writeCustomSecret(rotatedRefreshToken, named: "mcp-oauth-refresh-\(connectorIdentifier)")
            }
            cachedAccessTokensByConnector[connectorIdentifier] = (
                token: accessToken,
                expiryDate: Date().addingTimeInterval(((tokenJSON["expires_in"] as? Double) ?? 3600) - 60))
            return accessToken
        } catch {
            OrchestraLog.write("🔐 Connector \(connectorIdentifier): token refresh failed: \(error.localizedDescription)")
            return nil
        }
    }

    func signOut(connectorIdentifier: String) {
        KeychainStore.writeCustomSecret("", named: "mcp-oauth-refresh-\(connectorIdentifier)")
        cachedAccessTokensByConnector[connectorIdentifier] = nil
        clientRecordsByConnector[connectorIdentifier] = nil
        saveClientRecords()
    }

    private func saveClientRecords() {
        if let encodedData = try? JSONEncoder().encode(clientRecordsByConnector) {
            UserDefaults.standard.set(encodedData, forKey: Self.clientRecordsDefaultsKey)
        }
    }
}

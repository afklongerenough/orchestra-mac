//
//  MCPConnectors.swift
//  leanring-buddy
//
//  Custom connectors: any MCP server the user adds in the menu (a URL and,
//  if needed, a token) — Notion, Linear, GitHub, Zapier/Composio, their own.
//  Orchestra lists each server's tools and can call them by voice: Live mode
//  through the connector_tool tool, push-to-talk through a [CONNECTOR:] tag.
//
//  Safety, enforced in code: a tool that sends, posts, deletes, pays, shares
//  or is marked destructive by its server never runs straight away. It's
//  parked, Orchestra says exactly what it will do, and it runs only after the
//  user says yes (checked against what the user actually said).
//
//  Servers can take a bearer token (or carry their key in the URL), or the
//  user can sign in with OAuth ("Sign in" on the connector row) — that's how
//  Notion's hosted server works. See ConnectorOAuth.swift. Gmail, Google
//  Calendar and Drive are a built-in read-only connector (GoogleConnector.swift).
//

import Combine
import Foundation

struct MCPConnectorConfig: Codable, Identifiable, Equatable {
    /// Short lowercase name the model uses, e.g. "notion".
    var id: String
    var urlText: String
    var isEnabled: Bool
    /// True when this connector uses browser sign-in (OAuth) instead of a
    /// pasted token. Optional so connectors saved by older builds still load.
    var usesOAuth: Bool?
}

struct MCPToolInfo: Equatable {
    let name: String
    let description: String
    /// Compact "query*, limit" style summary of the arguments (* = required).
    let argumentSummary: String
    let isRisky: Bool
}

/// A minimal MCP client (streamable HTTP, JSON or SSE replies).
actor MCPHTTPClient {
    private let endpointURL: URL
    private let bearerToken: String?
    private var mcpSessionIdentifier: String?
    private var isInitialized = false
    private var nextRequestIdentifier = 1
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    struct MCPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(endpointURL: URL, bearerToken: String?) {
        self.endpointURL = endpointURL
        self.bearerToken = bearerToken
    }

    func listTools() async throws -> [[String: Any]] {
        try await initializeIfNeeded()
        var allTools: [[String: Any]] = []
        var nextCursor: String?
        repeat {
            var listParameters: [String: Any] = [:]
            if let nextCursor { listParameters["cursor"] = nextCursor }
            let result = try await sendRPC(method: "tools/list", params: listParameters)
            allTools.append(contentsOf: (result["tools"] as? [[String: Any]]) ?? [])
            nextCursor = result["nextCursor"] as? String
        } while nextCursor != nil && allTools.count < 400
        return allTools
    }

    func callTool(named toolName: String, arguments: [String: Any]) async throws -> String {
        try await initializeIfNeeded()
        let result = try await sendRPC(method: "tools/call", params: ["name": toolName, "arguments": arguments])
        let contentItems = (result["content"] as? [[String: Any]]) ?? []
        var resultText = contentItems.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if resultText.isEmpty, let structuredContent = result["structuredContent"],
           let structuredData = try? JSONSerialization.data(withJSONObject: structuredContent),
           let structuredText = String(data: structuredData, encoding: .utf8) {
            resultText = structuredText
        }
        if (result["isError"] as? Bool) == true {
            throw MCPError(message: "the tool reported an error: \(resultText.prefix(300))")
        }
        return resultText
    }

    private func initializeIfNeeded() async throws {
        guard !isInitialized else { return }
        _ = try await sendRPC(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "orchestra-mac", "version": "1.0.0"]
        ])
        let notificationRequest = try makeRequest(body: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        _ = try? await session.data(for: notificationRequest)
        isInitialized = true
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let mcpSessionIdentifier {
            request.setValue(mcpSessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sendRPC(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestIdentifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        let request = try makeRequest(body: ["jsonrpc": "2.0", "id": requestIdentifier, "method": method, "params": params])
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw MCPError(message: "no response") }
        if let newSessionIdentifier = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            mcpSessionIdentifier = newSessionIdentifier
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw MCPError(message: "the server refused the token (\(httpResponse.statusCode)); press Sign in on this connector if it uses OAuth, or check its token")
        }
        if httpResponse.statusCode == 404, mcpSessionIdentifier != nil {
            mcpSessionIdentifier = nil
            isInitialized = false
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MCPError(message: "server error \(httpResponse.statusCode): \((String(data: responseData, encoding: .utf8) ?? "").prefix(200))")
        }
        let bodyText = String(data: responseData, encoding: .utf8) ?? ""
        guard let message = Self.jsonRPCMessage(from: bodyText) else { throw MCPError(message: "couldn't read the server's reply") }
        if let rpcError = message["error"] as? [String: Any] {
            throw MCPError(message: rpcError["message"] as? String ?? "unknown error")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    private static func jsonRPCMessage(from bodyText: String) -> [String: Any]? {
        if bodyText.hasPrefix("event:") || bodyText.hasPrefix("data:") || bodyText.contains("\ndata:") {
            var lastMessage: [String: Any]?
            for line in bodyText.components(separatedBy: .newlines) where line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                   json["result"] != nil || json["error"] != nil {
                    lastMessage = json
                }
            }
            return lastMessage
        }
        return (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any]
    }
}

@MainActor
final class MCPConnectorManager: ObservableObject {
    static let shared = MCPConnectorManager()

    @Published private(set) var connectors: [MCPConnectorConfig] = []
    @Published private(set) var toolsByConnector: [String: [MCPToolInfo]] = [:]
    @Published private(set) var statusByConnector: [String: String] = [:]

    /// A risky call waiting for the user's spoken "yes".
    struct PendingConnectorCall {
        let connectorIdentifier: String
        let toolName: String
        let arguments: [String: Any]
        let createdDate: Date
    }
    private(set) var pendingRiskyCall: PendingConnectorCall?

    private static let connectorsDefaultsKey = "mcpConnectors"
    private var clientsByConnector: [String: MCPHTTPClient] = [:]
    /// The bearer token each cached client was built with. OAuth access
    /// tokens rotate, so a changed token means a fresh client.
    private var clientTokenByConnector: [String: String] = [:]

    /// Verbs that change things. Matched against the tool name split into
    /// words (send_email, sendMessage and SendMessage all become "send message").
    private nonisolated static let riskyToolVerbPattern = #"\b(send|delete|del|remove|rm|destroy|trash|post|publish|pay|payment|transfer|purchase|buy|order|book|refund|charge|invite|share|merge|deploy|reply|forward|archive|cancel|revoke|upload|move|rename|update|edit|modify|write|create|add|insert|set|put|patch|submit|approve|close|kill|drop|overwrite|unsubscribe|block|schedule|comment|like|follow|purge|wipe|clear|erase|reset|terminate|logout|revert|restore|empty|execute|exec|run)\b"#
    /// A tool counts as harmless only if it starts with one of these (or the
    /// server marks it read-only) and has no risky verb anywhere in its name.
    private nonisolated static let readOnlyToolVerbPattern = #"^(get|list|search|read|fetch|find|query|describe|lookup|look|view|show|check|count|retrieve|browse|preview)\b"#

    /// True only for a clear yes: it has to START with yes/sure/go ahead…, and
    /// any no/not/don't/wait/stop anywhere in it turns it into a no.
    nonisolated static func userSpeechConfirms(_ userSpeech: String) -> Bool {
        let normalizedSpeech = userSpeech.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z' ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let negationPattern = #"\b(no|nope|nah|not|don't|dont|do not|never|wait|stop|cancel|hold on|hang on|later|actually|but)\b"#
        guard normalizedSpeech.range(of: negationPattern, options: .regularExpression) == nil else { return false }
        // A short reply only: "okay so what time is the meeting" isn't a yes.
        guard normalizedSpeech.split(separator: " ").count <= 6 else { return false }
        let affirmativeStartPattern = #"^(yes|yeah|yep|yup|sure|ok|okay|confirm|confirmed|go ahead|do it|please do|send it|correct)\b"#
        return normalizedSpeech.range(of: affirmativeStartPattern, options: .regularExpression) != nil
    }

    private init() {
        if let savedData = UserDefaults.standard.data(forKey: Self.connectorsDefaultsKey),
           let savedConnectors = try? JSONDecoder().decode([MCPConnectorConfig].self, from: savedData) {
            connectors = savedConnectors
        }
    }

    // MARK: - Managing connectors

    /// Returns an error message, or nil when added.
    func addConnector(name: String, urlText: String, token: String, usesOAuth: Bool = false) -> String? {
        let connectorIdentifier = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !connectorIdentifier.isEmpty else { return "give it a short name" }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            return "the address must start with https://"
        }
        guard !connectors.contains(where: { $0.id == connectorIdentifier }) else { return "there's already a connector called \(connectorIdentifier)" }
        connectors.append(MCPConnectorConfig(id: connectorIdentifier, urlText: url.absoluteString, isEnabled: true, usesOAuth: usesOAuth ? true : nil))
        KeychainStore.writeCustomSecret(token, named: "mcp-token-\(connectorIdentifier)")
        saveConnectors()
        Task { await refreshTools(connectorIdentifier: connectorIdentifier) }
        return nil
    }

    /// Browser sign-in (OAuth) for one connector — Notion's hosted server and
    /// any other MCP server that advertises OAuth endpoints. Returns a short
    /// status line for the menu.
    func signIn(connectorIdentifier: String) async -> String {
        guard let connector = connectors.first(where: { $0.id == connectorIdentifier }) else { return "no such connector" }
        let signInStatus = await ConnectorOAuthManager.shared.signIn(connectorIdentifier: connectorIdentifier,
                                                                     serverURLText: connector.urlText)
        guard signInStatus == "signed in" else { return signInStatus }
        if let connectorIndex = connectors.firstIndex(where: { $0.id == connectorIdentifier }) {
            connectors[connectorIndex].usesOAuth = true
            saveConnectors()
        }
        clientsByConnector[connectorIdentifier] = nil
        clientTokenByConnector[connectorIdentifier] = nil
        await refreshTools(connectorIdentifier: connectorIdentifier)
        return "signed in — \(statusByConnector[connectorIdentifier] ?? "checking tools")"
    }

    func removeConnector(connectorIdentifier: String) {
        connectors.removeAll { $0.id == connectorIdentifier }
        KeychainStore.writeCustomSecret("", named: "mcp-token-\(connectorIdentifier)")
        ConnectorOAuthManager.shared.signOut(connectorIdentifier: connectorIdentifier)
        clientsByConnector[connectorIdentifier] = nil
        clientTokenByConnector[connectorIdentifier] = nil
        toolsByConnector[connectorIdentifier] = nil
        statusByConnector[connectorIdentifier] = nil
        saveConnectors()
    }

    func setConnector(connectorIdentifier: String, enabled isEnabled: Bool) {
        guard let connectorIndex = connectors.firstIndex(where: { $0.id == connectorIdentifier }) else { return }
        connectors[connectorIndex].isEnabled = isEnabled
        saveConnectors()
        if isEnabled { Task { await refreshTools(connectorIdentifier: connectorIdentifier) } }
    }

    private func saveConnectors() {
        if let encodedData = try? JSONEncoder().encode(connectors) {
            UserDefaults.standard.set(encodedData, forKey: Self.connectorsDefaultsKey)
        }
    }

    func refreshAllTools() async {
        for connector in connectors where connector.isEnabled {
            await refreshTools(connectorIdentifier: connector.id)
        }
    }

    func refreshTools(connectorIdentifier: String) async {
        guard connectors.contains(where: { $0.id == connectorIdentifier && $0.isEnabled }) else { return }
        guard let client = await client(for: connectorIdentifier) else {
            let usesOAuth = connectors.first(where: { $0.id == connectorIdentifier })?.usesOAuth == true
            statusByConnector[connectorIdentifier] = usesOAuth ? "needs sign-in (press Sign in)" : "bad address"
            return
        }
        statusByConnector[connectorIdentifier] = "connecting…"
        do {
            let rawTools = try await client.listTools()
            var parsedTools: [MCPToolInfo] = []
            for rawTool in rawTools {
                if let parsedTool = Self.toolInfo(from: rawTool) { parsedTools.append(parsedTool) }
            }
            toolsByConnector[connectorIdentifier] = parsedTools
            statusByConnector[connectorIdentifier] = "\(toolsByConnector[connectorIdentifier]?.count ?? 0) tools"
        } catch {
            toolsByConnector[connectorIdentifier] = []
            statusByConnector[connectorIdentifier] = error.localizedDescription
            OrchestraLog.write("🔌 Connector \(connectorIdentifier): \(error.localizedDescription)")
        }
    }

    /// Builds (or reuses) the HTTP client with a current bearer token: the
    /// pasted token, or a fresh OAuth access token for sign-in connectors.
    private func client(for connectorIdentifier: String) async -> MCPHTTPClient? {
        guard let connector = connectors.first(where: { $0.id == connectorIdentifier && $0.isEnabled }),
              let endpointURL = URL(string: connector.urlText) else { return nil }
        let bearerToken: String?
        if connector.usesOAuth == true {
            bearerToken = await ConnectorOAuthManager.shared.validAccessToken(connectorIdentifier: connectorIdentifier)
            guard bearerToken != nil else { return nil }
        } else {
            bearerToken = KeychainStore.readCustomSecret(named: "mcp-token-\(connectorIdentifier)")
        }
        if let existingClient = clientsByConnector[connectorIdentifier],
           clientTokenByConnector[connectorIdentifier] == (bearerToken ?? "") {
            return existingClient
        }
        let newClient = MCPHTTPClient(endpointURL: endpointURL, bearerToken: bearerToken)
        clientsByConnector[connectorIdentifier] = newClient
        clientTokenByConnector[connectorIdentifier] = bearerToken ?? ""
        return newClient
    }

    private nonisolated static func toolInfo(from rawTool: [String: Any]) -> MCPToolInfo? {
        guard let toolName = rawTool["name"] as? String else { return nil }
        let toolDescription = ((rawTool["description"] as? String) ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let inputSchema = rawTool["inputSchema"] as? [String: Any] ?? [:]
        let requiredNames = Set(inputSchema["required"] as? [String] ?? [])
        let propertyNames = (inputSchema["properties"] as? [String: Any])?.keys.sorted() ?? []
        let argumentSummary = propertyNames.map { requiredNames.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
        let annotations = rawTool["annotations"] as? [String: Any] ?? [:]
        let isMarkedReadOnly = (annotations["readOnlyHint"] as? Bool) == true
        let isMarkedDestructive = (annotations["destructiveHint"] as? Bool) == true
        // "sendMessage" / "SendMessage" / "send-message" → "send message"
        let toolNameWords = toolName
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[_\-.\s/:]+"#, with: " ", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        let nameSoundsRisky = toolNameWords.range(of: riskyToolVerbPattern, options: .regularExpression) != nil
        let nameSoundsReadOnly = toolNameWords.range(of: readOnlyToolVerbPattern, options: .regularExpression) != nil
        // A server's readOnlyHint never overrides a risky-sounding name; anything
        // that isn't clearly a read needs the user's yes.
        let isRisky = isMarkedDestructive || nameSoundsRisky || !(isMarkedReadOnly || nameSoundsReadOnly)
        return MCPToolInfo(name: toolName,
                           description: String(toolDescription.prefix(140)),
                           argumentSummary: argumentSummary,
                           isRisky: isRisky)
    }

    // MARK: - For the models

    var hasUsableTools: Bool { toolsByConnector.values.contains { !$0.isEmpty } }

    /// The tool list for system prompts (kept short).
    var toolCatalogForPrompt: String {
        var catalogLines: [String] = []
        for connector in connectors where connector.isEnabled {
            guard let connectorTools = toolsByConnector[connector.id], !connectorTools.isEmpty else { continue }
            catalogLines.append("connector \"\(connector.id)\":")
            for toolInfo in connectorTools.prefix(40) {
                catalogLines.append("- \(toolInfo.name)(\(toolInfo.argumentSummary))\(toolInfo.isRisky ? " [needs the user's yes]" : ""): \(toolInfo.description)")
            }
        }
        return String(catalogLines.joined(separator: "\n").prefix(7000))
    }

    /// Runs a tool, or parks it if it's risky. Returns text for the model.
    func runTool(connectorIdentifier: String, toolName: String, argumentsJSONText: String) async -> String {
        guard let connectorTools = toolsByConnector[connectorIdentifier],
              let toolInfo = connectorTools.first(where: { $0.name == toolName }) else {
            return "no tool \(toolName) on connector \(connectorIdentifier). available: \(toolsByConnector[connectorIdentifier]?.map(\.name).joined(separator: ", ") ?? "none")"
        }
        let parsedArguments: [String: Any]
        if argumentsJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsedArguments = [:]
        } else if let decodedArguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSONText.utf8))) as? [String: Any] {
            parsedArguments = decodedArguments
        } else {
            return "arguments must be a JSON object, e.g. {\"query\": \"...\"}"
        }
        if toolInfo.isRisky {
            // Only one action waits at a time; a new one replaces the old, and only a
            // yes said after this moment counts (see runPendingRiskyCall).
            if let replacedCall = pendingRiskyCall {
                OrchestraLog.write("🔌 Dropped the earlier parked \(replacedCall.toolName) for \(toolName)")
            }
            pendingRiskyCall = PendingConnectorCall(connectorIdentifier: connectorIdentifier, toolName: toolName,
                                                    arguments: parsedArguments, createdDate: Date())
            OrchestraLog.write("🔌 Parked for the user's yes: \(connectorIdentifier).\(toolName)")
            return "not run yet: \(toolName) may change things. tell the user exactly what it will do (\(Self.compactJSON(parsedArguments).prefix(200))) and ask them to say yes. it runs only after they confirm, and only this one action (any earlier waiting action was dropped)."
        }
        return await execute(connectorIdentifier: connectorIdentifier, toolName: toolName, arguments: parsedArguments)
    }

    /// Runs the parked action if the user really said yes within 2 minutes.
    /// `userSpeechAfterParking` must hold only what the user said AFTER the
    /// action was parked; `expectedToolName` (when given) must match it.
    func runPendingRiskyCall(userSpeechAfterParking userSpeech: String, expectedToolName: String? = nil) async -> String {
        guard let pendingRiskyCall, Date().timeIntervalSince(pendingRiskyCall.createdDate) < 120 else {
            self.pendingRiskyCall = nil
            return "nothing is waiting for a yes (or it expired). ask for it again."
        }
        // The model may say "connector.tool"; compare the tool part only.
        let expectedBareToolName = expectedToolName?.split(separator: ".").last.map(String.init) ?? ""
        if !expectedBareToolName.isEmpty, expectedBareToolName != pendingRiskyCall.toolName {
            return "the action waiting for a yes is \(pendingRiskyCall.toolName), not \(expectedBareToolName). tell the user what's waiting and ask again."
        }
        guard Self.userSpeechConfirms(userSpeech) else {
            return "the user hasn't clearly said yes (a yes has to come after you asked, with no 'no', 'wait' or 'not'). ask them, and only confirm after they do."
        }
        self.pendingRiskyCall = nil
        OrchestraLog.write("🔌 User confirmed: \(pendingRiskyCall.connectorIdentifier).\(pendingRiskyCall.toolName)")
        return await execute(connectorIdentifier: pendingRiskyCall.connectorIdentifier,
                             toolName: pendingRiskyCall.toolName, arguments: pendingRiskyCall.arguments)
    }

    func cancelPendingRiskyCall() { pendingRiskyCall = nil }

    private func execute(connectorIdentifier: String, toolName: String, arguments: [String: Any]) async -> String {
        guard let client = await client(for: connectorIdentifier) else {
            let usesOAuth = connectors.first(where: { $0.id == connectorIdentifier })?.usesOAuth == true
            return usesOAuth
                ? "connector \(connectorIdentifier) needs a fresh sign-in; ask the user to press Sign in on it under connections"
                : "connector \(connectorIdentifier) is off or missing"
        }
        do {
            let resultText = try await client.callTool(named: toolName, arguments: arguments)
            OrchestraLog.write("🔌 \(connectorIdentifier).\(toolName) ok (\(resultText.count) chars)")
            return String(resultText.prefix(6000))
        } catch {
            OrchestraLog.write("🔌 \(connectorIdentifier).\(toolName) failed: \(error.localizedDescription)")
            return "failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func compactJSON(_ jsonObject: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else { return "{}" }
        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }
}

/// Finds `[CONNECTOR: name tool {json}]` in a reply (the JSON may contain brackets).
enum ConnectorTagParser {
    struct ConnectorCall {
        let connectorIdentifier: String
        let toolName: String
        let argumentsJSONText: String
    }

    static func extractConnectorCall(from replyText: String) -> (call: ConnectorCall?, remainingText: String) {
        guard let tagStartRange = replyText.range(of: "[CONNECTOR:") else { return (nil, replyText) }
        var scanIndex = tagStartRange.upperBound
        func skipSpaces() {
            while scanIndex < replyText.endIndex, replyText[scanIndex].isWhitespace { scanIndex = replyText.index(after: scanIndex) }
        }
        func readWord() -> String {
            skipSpaces()
            let wordStart = scanIndex
            while scanIndex < replyText.endIndex, !replyText[scanIndex].isWhitespace, replyText[scanIndex] != "{", replyText[scanIndex] != "]" {
                scanIndex = replyText.index(after: scanIndex)
            }
            return String(replyText[wordStart..<scanIndex])
        }
        let connectorIdentifier = readWord()
        let toolName = readWord()
        skipSpaces()
        var argumentsJSONText = "{}"
        if scanIndex < replyText.endIndex, replyText[scanIndex] == "{" {
            // Walk to the matching closing brace, ignoring braces inside strings.
            let jsonStart = scanIndex
            var braceDepth = 0
            var isInsideString = false
            var isEscaped = false
            while scanIndex < replyText.endIndex {
                let character = replyText[scanIndex]
                if isInsideString {
                    if isEscaped { isEscaped = false }
                    else if character == "\\" { isEscaped = true }
                    else if character == "\"" { isInsideString = false }
                } else if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    braceDepth += 1
                } else if character == "}" {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        scanIndex = replyText.index(after: scanIndex)
                        break
                    }
                }
                scanIndex = replyText.index(after: scanIndex)
            }
            argumentsJSONText = String(replyText[jsonStart..<scanIndex])
        }
        // Up to and including the closing "]".
        if let closingBracketIndex = replyText[scanIndex...].firstIndex(of: "]") {
            scanIndex = replyText.index(after: closingBracketIndex)
        }
        var remainingText = replyText
        remainingText.removeSubrange(tagStartRange.lowerBound..<scanIndex)
        guard !connectorIdentifier.isEmpty, !toolName.isEmpty else {
            return (nil, remainingText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (ConnectorCall(connectorIdentifier: connectorIdentifier, toolName: toolName, argumentsJSONText: argumentsJSONText),
                remainingText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

//
//  HermesBridgeClient.swift
//  leanring-buddy
//
//  Minimal MCP (streamable HTTP) client for the user's Hermes bridge — the same
//  server that gives Claude the `hermes_task` / `hermes_task_status` tools.
//  Orchestra uses it to hand Hermes background jobs and poll for results.
//
//  Protocol notes: every call is a JSON-RPC POST to the bridge URL. The
//  server may answer with plain JSON or with a short SSE stream ("data:"
//  lines), and may hand back an `Mcp-Session-Id` header that must be sent
//  on later calls.
//

import Foundation

struct HermesBridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What `hermes_task_status` reports for one task.
struct HermesTaskStatus: Sendable {
    let taskIdentifier: String
    let state: String          // "running", "done", "failed", ...
    let outputText: String
    let errorText: String?

    var isFinished: Bool { state != "running" && state != "queued" && state != "pending" }
    var didSucceed: Bool { state == "done" || state == "completed" || state == "succeeded" }
}

actor HermesBridgeClient {
    static let bridgeURLDefaultsKey = "hermesBridgeURL"

    private let session: URLSession
    private var mcpSessionIdentifier: String?
    private var isInitialized = false
    private var nextRequestIdentifier = 1

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// No default: the user pastes their own Hermes bridge URL
    /// in the Connections settings.
    static let defaultBridgeURLText = ""

    static var configuredBridgeURL: URL? {
        let savedURLText = UserDefaults.standard.string(forKey: bridgeURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeURLText = (savedURLText?.isEmpty == false) ? savedURLText! : defaultBridgeURLText
        return URL(string: bridgeURLText)
    }

    /// The bridge always needs a bearer token, so "configured" means we have one.
    static var isConfigured: Bool { configuredBridgeURL != nil && KeychainStore.read(.hermesBridgeToken) != nil }

    /// Forget the MCP session (e.g. after the URL or token changes).
    func resetConnection() {
        mcpSessionIdentifier = nil
        isInitialized = false
    }

    // MARK: - Public tool calls

    /// Starts a Hermes task and returns its task id.
    func startTask(prompt: String, timeoutSeconds: Int = 900) async throws -> String {
        let resultText = try await callTool(
            named: "hermes_task",
            arguments: ["prompt": prompt, "timeout_s": timeoutSeconds]
        )
        if let json = Self.parseJSONObject(resultText), let taskIdentifier = json["id"] as? String {
            return taskIdentifier
        }
        // Fall back to finding something that looks like "task_..." in plain text.
        if let range = resultText.range(of: #"task_[A-Za-z0-9_]+"#, options: .regularExpression) {
            return String(resultText[range])
        }
        throw HermesBridgeError(message: "hermes didn't return a task id: \(resultText.prefix(200))")
    }

    func cancelTask(taskIdentifier: String) async throws {
        _ = try await callTool(named: "hermes_task_cancel", arguments: ["id": taskIdentifier])
    }

    func taskStatus(taskIdentifier: String) async throws -> HermesTaskStatus {
        let resultText = try await callTool(named: "hermes_task_status", arguments: ["id": taskIdentifier])
        guard let json = Self.parseJSONObject(resultText) else {
            return HermesTaskStatus(taskIdentifier: taskIdentifier, state: "unknown", outputText: resultText, errorText: nil)
        }
        let errorValue = json["error"]
        let errorText: String? = (errorValue is NSNull) ? nil : (errorValue as? String)
        return HermesTaskStatus(
            taskIdentifier: taskIdentifier,
            state: (json["status"] as? String) ?? "unknown",
            outputText: (json["output"] as? String) ?? "",
            errorText: errorText
        )
    }

    // MARK: - MCP plumbing

    private func callTool(named toolName: String, arguments: [String: Any]) async throws -> String {
        try await initializeIfNeeded()
        let result = try await sendRPC(method: "tools/call", params: ["name": toolName, "arguments": arguments])

        // Tool results come back as { content: [{type:"text", text:"..."}], isError? }
        let contentItems = (result["content"] as? [[String: Any]]) ?? []
        let text = contentItems.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if (result["isError"] as? Bool) == true {
            throw HermesBridgeError(message: "hermes tool error: \(text.prefix(300))")
        }
        if text.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured),
           let structuredText = String(data: data, encoding: .utf8) {
            return structuredText
        }
        return text
    }

    private func initializeIfNeeded() async throws {
        guard !isInitialized else { return }
        _ = try await sendRPC(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "orchestra-mac", "version": "1.0.0"]
        ])
        try await sendNotification(method: "notifications/initialized")
        isInitialized = true
    }

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        guard let bridgeURL = Self.configuredBridgeURL else {
            throw HermesBridgeError(message: "hermes bridge url isn't set. add it in the orchestra menu.")
        }
        var request = URLRequest(url: bridgeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2024-11-05", forHTTPHeaderField: "MCP-Protocol-Version")
        // ngrok's free tier can show a browser warning page; this header skips it.
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let bridgeToken = KeychainStore.read(.hermesBridgeToken) {
            request.setValue("Bearer \(bridgeToken)", forHTTPHeaderField: "Authorization")
        }
        if let mcpSessionIdentifier {
            request.setValue(mcpSessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sendNotification(method: String) async throws {
        let request = try makeRequest(body: ["jsonrpc": "2.0", "method": method])
        _ = try await session.data(for: request)
    }

    private func sendRPC(method: String, params: [String: Any]) async throws -> [String: Any] {
        let requestIdentifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        let request = try makeRequest(body: [
            "jsonrpc": "2.0",
            "id": requestIdentifier,
            "method": method,
            "params": params
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesBridgeError(message: "no response from the hermes bridge")
        }
        if let newSessionIdentifier = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            mcpSessionIdentifier = newSessionIdentifier
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw HermesBridgeError(message: "the hermes bridge rejected the token (\(http.statusCode))")
        }
        if http.statusCode == 404, mcpSessionIdentifier != nil {
            // Session expired on the server; start over next call.
            resetConnection()
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw HermesBridgeError(message: "hermes bridge error \(http.statusCode): \(bodyText.prefix(200))")
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let message = Self.extractJSONRPCMessage(from: bodyText, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        guard let message else {
            throw HermesBridgeError(message: "couldn't read the hermes bridge reply")
        }
        if let rpcError = message["error"] as? [String: Any] {
            throw HermesBridgeError(message: "hermes bridge: \(rpcError["message"] as? String ?? "unknown error")")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    /// Handles both plain JSON bodies and SSE bodies ("event: message\ndata: {...}").
    private static func extractJSONRPCMessage(from bodyText: String, contentType: String?) -> [String: Any]? {
        if contentType?.contains("text/event-stream") == true || bodyText.hasPrefix("event:") || bodyText.hasPrefix("data:") {
            var lastMessageWithResult: [String: Any]?
            for line in bodyText.components(separatedBy: .newlines) where line.hasPrefix("data:") {
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if let json = parseJSONObject(payload), json["result"] != nil || json["error"] != nil {
                    lastMessageWithResult = json
                }
            }
            return lastMessageWithResult
        }
        return parseJSONObject(bodyText)
    }

    private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

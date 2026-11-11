//
//  OpenCodeGoClient.swift
//  leanring-buddy
//
//  the user's OpenCode Go plan as Orchestra's "brain" (default model
//  deepseek-v4.1-flash, which Hermes verified sees images and calls tools).
//  Uses the OpenAI-compatible endpoint:
//    POST https://opencode.ai/inference/go/openai/v1/chat/completions
//    Authorization: Bearer oc_sk_…   x-opencode-session: ses_…   User-Agent: orchestra-mac/1.0
//
//  GeminiAPI routes here when the brain is set to OpenCode Go, so the rest of
//  the app keeps speaking Gemini's request/response shapes:
//    • analyzeImage → chat messages with image_url data URIs → reply text
//    • generateContentRaw (Mac agent function calling) → Gemini contents/tools
//      converted to OpenAI messages/tools, and the reply converted back to a
//      Gemini-shaped {"candidates":[{"content":{"parts":[…]}}]}.
//
//  A stable session id per app run lets OpenCode reuse DeepSeek's prompt
//  cache (Orchestra's long instructions are the same every call).
//

import Foundation

enum BrainProvider: String {
    case opencodeGo = "opencode"
    case gemini = "gemini"

    static let defaultsKey = "orchestraBrainProvider"
    static let openCodeModelDefaultsKey = "openCodeGoModel"
    static let defaultOpenCodeModel = "deepseek-v4.1-flash"

    /// OpenCode Go when a key is saved and the user hasn't switched to Gemini.
    static var current: BrainProvider {
        let savedProvider = UserDefaults.standard.string(forKey: defaultsKey).flatMap(BrainProvider.init(rawValue:))
        if savedProvider == .gemini { return .gemini }
        return KeychainStore.read(.openCodeAPIKey) != nil ? .opencodeGo : .gemini
    }

    static var openCodeModel: String {
        let savedModel = UserDefaults.standard.string(forKey: openCodeModelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (savedModel?.isEmpty == false) ? savedModel! : defaultOpenCodeModel
    }
}

struct OpenCodeGoError: LocalizedError {
    let message: String
    let statusCode: Int
    var errorDescription: String? { message }
}

final class OpenCodeGoClient {
    private static let chatCompletionsURL = URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!
    /// One session id per app run so OpenCode can reuse the prompt cache.
    private static let sessionIdentifier = "ses_orchestra_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    // MARK: - Screen + voice answers

    func answer(images: [(data: Data, label: String)],
                systemPrompt: String,
                conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
                userPrompt: String,
                imageMimeType: (Data) -> String) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for (userText, assistantText) in conversationHistory {
            messages.append(["role": "user", "content": userText])
            messages.append(["role": "assistant", "content": assistantText])
        }
        var currentContentParts: [[String: Any]] = []
        for image in images {
            currentContentParts.append(["type": "text", "text": image.label])
            let imageURL: [String: Any] = ["url": "data:\(imageMimeType(image.data));base64,\(image.data.base64EncodedString())"]
            currentContentParts.append(["type": "image_url", "image_url": imageURL])
        }
        currentContentParts.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": currentContentParts])

        let responseJSON = try await postChatCompletion(body: [
            "model": BrainProvider.openCodeModel,
            "messages": messages,
            "max_tokens": 2048,
            "temperature": 0.7
        ])
        guard let message = Self.firstMessage(in: responseJSON) else {
            throw OpenCodeGoError(message: "opencode returned no answer", statusCode: 0)
        }
        let answerText = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answerText.isEmpty else {
            throw OpenCodeGoError(message: "opencode returned an empty answer", statusCode: 0)
        }
        return answerText
    }

    // MARK: - Gemini-shaped function calling (for the Mac agent)

    func generateContentRaw(geminiBody: [String: Any]) async throws -> [String: Any] {
        var messages: [[String: Any]] = []
        if let systemInstruction = geminiBody["systemInstruction"] as? [String: Any],
           let systemParts = systemInstruction["parts"] as? [[String: Any]] {
            let systemText = systemParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            messages.append(["role": "system", "content": systemText])
        }

        // Tool calls get ids derived from their position, so the same history
        // always converts to the same ids and responses can be matched in order.
        // (id, function name) of the last assistant turn's calls still waiting for a result.
        var pendingToolCalls: [(identifier: String, functionName: String)] = []
        let geminiContents = geminiBody["contents"] as? [[String: Any]] ?? []
        for (turnIndex, geminiTurn) in geminiContents.enumerated() {
            let role = geminiTurn["role"] as? String ?? "user"
            let parts = geminiTurn["parts"] as? [[String: Any]] ?? []

            if role == "model" {
                let assistantText = parts.filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }.joined()
                var toolCalls: [[String: Any]] = []
                appendPlaceholderResults(for: &pendingToolCalls, into: &messages)
                for (partIndex, part) in parts.enumerated() {
                    guard let functionCall = part["functionCall"] as? [String: Any] else { continue }
                    let toolCallIdentifier = "call_\(turnIndex)_\(partIndex)"
                    pendingToolCalls.append((identifier: toolCallIdentifier, functionName: functionCall["name"] as? String ?? ""))
                    let argumentsObject = functionCall["args"] as? [String: Any] ?? [:]
                    let argumentsData = (try? JSONSerialization.data(withJSONObject: argumentsObject)) ?? Data("{}".utf8)
                    let functionPayload: [String: Any] = [
                        "name": functionCall["name"] as? String ?? "",
                        "arguments": String(data: argumentsData, encoding: .utf8) ?? "{}"
                    ]
                    toolCalls.append(["id": toolCallIdentifier, "type": "function", "function": functionPayload])
                }
                var assistantMessage: [String: Any] = ["role": "assistant"]
                assistantMessage["content"] = (assistantText.isEmpty && !toolCalls.isEmpty) ? NSNull() : assistantText
                if !toolCalls.isEmpty { assistantMessage["tool_calls"] = toolCalls }
                messages.append(assistantMessage)
                continue
            }

            let functionResponses = parts.compactMap { $0["functionResponse"] as? [String: Any] }
            for functionResponse in functionResponses {
                // Match by function name (first unanswered call with that name); drop strays.
                let functionName = functionResponse["name"] as? String ?? ""
                guard let matchIndex = pendingToolCalls.firstIndex(where: { $0.functionName == functionName }) else { continue }
                let matchedToolCall = pendingToolCalls.remove(at: matchIndex)
                let responseObject = functionResponse["response"] as? [String: Any] ?? [:]
                let responseText = (responseObject["result"] as? String)
                    ?? (String(data: (try? JSONSerialization.data(withJSONObject: responseObject)) ?? Data(), encoding: .utf8) ?? "")
                messages.append(["role": "tool", "tool_call_id": matchedToolCall.identifier, "content": responseText])
            }
            // Any call that got no result still needs one, or the API rejects the history.
            appendPlaceholderResults(for: &pendingToolCalls, into: &messages)

            let userText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !userText.isEmpty {
                messages.append(["role": "user", "content": userText])
            }
        }

        appendPlaceholderResults(for: &pendingToolCalls, into: &messages)

        var openAITools: [[String: Any]] = []
        if let geminiTools = geminiBody["tools"] as? [[String: Any]] {
            for toolGroup in geminiTools {
                for declaration in toolGroup["functionDeclarations"] as? [[String: Any]] ?? [] {
                    let functionDefinition: [String: Any] = [
                        "name": declaration["name"] as? String ?? "",
                        "description": declaration["description"] as? String ?? "",
                        "parameters": declaration["parameters"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
                    ]
                    openAITools.append(["type": "function", "function": functionDefinition])
                }
            }
        }

        var requestBody: [String: Any] = [
            "model": BrainProvider.openCodeModel,
            "messages": messages,
            "max_tokens": 8192
        ]
        if !openAITools.isEmpty {
            requestBody["tools"] = openAITools
            requestBody["tool_choice"] = "auto"
        }

        let responseJSON = try await postChatCompletion(body: requestBody)
        guard let message = Self.firstMessage(in: responseJSON) else {
            throw OpenCodeGoError(message: "opencode returned no answer", statusCode: 0)
        }
        let finishReason = ((responseJSON["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String) ?? ""
        let returnedToolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        if finishReason == "length" && returnedToolCalls.isEmpty {
            // Don't let a cut-off reply look like "done".
            throw OpenCodeGoError(message: "the model's reply was cut off", statusCode: 0)
        }

        // Back to Gemini's shape: text part + functionCall parts.
        var geminiParts: [[String: Any]] = []
        if let replyText = message["content"] as? String, !replyText.isEmpty {
            geminiParts.append(["text": replyText])
        }
        for toolCall in returnedToolCalls {
            guard let function = toolCall["function"] as? [String: Any] else { continue }
            let argumentsText = (function["arguments"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Never run a tool with made-up empty arguments from truncated JSON.
            guard let argumentsObject = argumentsText.isEmpty
                    ? [String: Any]()
                    : (try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8))) as? [String: Any] else {
                print("⚠️ OpenCode: skipped a tool call with unreadable arguments")
                continue
            }
            let functionCall: [String: Any] = ["name": function["name"] as? String ?? "", "args": argumentsObject]
            geminiParts.append(["functionCall": functionCall])
        }
        let survivingFunctionCallCount = geminiParts.filter { $0["functionCall"] != nil }.count
        if !returnedToolCalls.isEmpty && survivingFunctionCallCount == 0 {
            // Every tool call was unreadable (usually a cut-off reply): never report "done".
            throw OpenCodeGoError(message: "the model's tool call came back garbled", statusCode: 0)
        }
        if geminiParts.isEmpty {
            geminiParts.append(["text": ""])
        }
        let geminiContent: [String: Any] = ["role": "model", "parts": geminiParts]
        return ["candidates": [["content": geminiContent]]]
    }

    /// Adds a "no result" tool message for each call that never got one.
    private func appendPlaceholderResults(for pendingToolCalls: inout [(identifier: String, functionName: String)],
                                          into messages: inout [[String: Any]]) {
        for unansweredToolCall in pendingToolCalls {
            messages.append(["role": "tool", "tool_call_id": unansweredToolCall.identifier, "content": "(no result: this call was skipped)"])
        }
        pendingToolCalls.removeAll()
    }

    // MARK: - HTTP

    private func postChatCompletion(body: [String: Any]) async throws -> [String: Any] {
        guard let apiKey = KeychainStore.read(.openCodeAPIKey) else {
            throw OpenCodeGoError(message: "no opencode key saved", statusCode: 401)
        }
        var request = URLRequest(url: Self.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.sessionIdentifier, forHTTPHeaderField: "x-opencode-session")
        request.setValue("orchestra-mac/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Up to 3 tries for busy/timeout errors (429 rate limit, 5xx, network timeout).
        var data = Data()
        var statusCode = 0
        for attemptNumber in 1...3 {
            try Task.checkCancellation()
            do {
                let (responseData, response) = try await session.data(for: request)
                data = responseData
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let urlError as URLError where urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                statusCode = 599
                if attemptNumber < 3 { try await Task.sleep(nanoseconds: UInt64(attemptNumber) * 3_000_000_000); continue }
                throw OpenCodeGoError(message: "opencode didn't answer in time", statusCode: 599)
            }
            let isRetryable = statusCode == 429 || (500...599).contains(statusCode)
            if isRetryable && attemptNumber < 3 {
                try await Task.sleep(nanoseconds: UInt64(attemptNumber) * 3_000_000_000)
                continue
            }
            break
        }
        guard (200...299).contains(statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            print("⚠️ OpenCode Go error \(statusCode): \(errorBody.prefix(300))")
            let friendlyMessage: String
            switch statusCode {
            case 401: friendlyMessage = "the opencode key doesn't work or expired"
            case 403: friendlyMessage = "opencode refused this model for your key"
            case 429: friendlyMessage = "the opencode go limit for this model is used up for now"
            default: friendlyMessage = "opencode had a problem (error \(statusCode))"
            }
            throw OpenCodeGoError(message: friendlyMessage, statusCode: statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeGoError(message: "opencode sent something that isn't json", statusCode: statusCode)
        }
        if let usage = json["usage"] as? [String: Any], let openCodeUsage = usage["opencode"] as? [String: Any],
           let tokens = openCodeUsage["tokens"] as? [String: Any] {
            print("🧾 OpenCode: input \(tokens["input"] ?? "?"), cached \(tokens["cache_read"] ?? "?"), output \(tokens["output"] ?? "?")")
        }
        return json
    }

    private static func firstMessage(in responseJSON: [String: Any]) -> [String: Any]? {
        guard let choices = responseJSON["choices"] as? [[String: Any]] else { return nil }
        return choices.first?["message"] as? [String: Any]
    }
}

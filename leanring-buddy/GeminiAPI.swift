//
//  GeminiAPI.swift
//  leanring-buddy
//
//  Gemini vision client used for every voice answer. Mirrors the old
//  ClaudeAPI.analyzeImageStreaming signature so CompanionManager barely
//  changes. Calls the Gemini REST API directly with the user's own key
//  (stored in the Keychain), so no proxy worker is needed.
//

import Foundation

struct GeminiAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class GeminiAPI {
    struct GeminiModelOption: Identifiable {
        let id: String
        let label: String
    }

    static let availableModels: [GeminiModelOption] = [
        GeminiModelOption(id: "gemini-3.5-flash", label: "3.5 Flash"),
        GeminiModelOption(id: "gemini-3.8-flash", label: "3.8 Flash"),
        GeminiModelOption(id: "gemini-3.1-flash-lite", label: "Lite")
    ]
    static let defaultModel = "gemini-3.5-flash"

    var model: String
    private let session: URLSession

    init(model: String = GeminiAPI.defaultModel) {
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    static var hasAPIKey: Bool { KeychainStore.read(.geminiAPIKey) != nil }

    /// When the brain is OpenCode Go, requests go there first and fall back
    /// to Gemini (if a Gemini key exists) only if OpenCode fails.
    private let openCodeGoClient = OpenCodeGoClient()

    // MARK: - Smarter model (for escalation and screen takeover)

    private static let resolvedSmartModelDefaultsKey = "resolvedSmartGeminiModel"
    private static let resolvedSmartModelDateDefaultsKey = "resolvedSmartGeminiModelDate"
    static let fallbackSmartModel = "gemini-3.8-flash"

    /// Finds the newest stable Gemini "pro" model this key can use by listing
    /// models once a day, so we never hardcode a name that goes stale.
    /// Falls back to the newest Flash if no pro model is available.
    static func resolveSmartModel() async -> String {
        let defaults = UserDefaults.standard
        if let cachedModel = defaults.string(forKey: resolvedSmartModelDefaultsKey), !isQuotaBlocked(cachedModel),
           let cachedDate = defaults.object(forKey: resolvedSmartModelDateDefaultsKey) as? Date,
           Date().timeIntervalSince(cachedDate) < 24 * 60 * 60 {
            return cachedModel
        }
        guard let apiKey = KeychainStore.read(.geminiAPIKey),
              let listURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200") else {
            return fallbackSmartModel
        }
        var request = URLRequest(url: listURL)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let listResponse = try? await URLSession.shared.data(for: request),
              (listResponse.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: listResponse.0) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            // Network or key problem: use the fallback but don't cache it.
            return fallbackSmartModel
        }

        // Pick the newest general-purpose "pro" model. Real ids look like
        // "gemini-3.5-pro", "gemini-3-pro-preview", "gemini-2.5-pro-preview-06-05";
        // skip special-purpose variants (tts, image, audio, live, embedding...).
        // Stable beats preview at the same version; versions compare part by part.
        let excludedNameFragments = ["tts", "image", "audio", "live", "embedding", "vision", "computer-use", "robotics", "thinking-exp"]
        var bestModelName: String?
        var bestRankKey: [Int] = []
        for model in models {
            guard let fullName = model["name"] as? String,
                  fullName.hasPrefix("models/gemini-"),
                  !isQuotaBlocked(String(fullName.dropFirst("models/".count))),
                  fullName.contains("-pro"),
                  !excludedNameFragments.contains(where: { fullName.contains($0) }) else { continue }
            let supportedMethods = model["supportedGenerationMethods"] as? [String] ?? ["generateContent"]
            guard supportedMethods.contains("generateContent") else { continue }

            let shortName = String(fullName.dropFirst("models/".count))
            let versionText = shortName.dropFirst("gemini-".count).prefix(while: { $0.isNumber || $0 == "." })
            let versionParts = versionText.split(separator: ".").compactMap { Int($0) }
            guard !versionParts.isEmpty else { continue }
            let stabilityScore = shortName.contains("preview") || shortName.contains("exp") ? 0 : 1
            // [major, minor, stable?] — e.g. 3.10 beats 3.9 because parts are compared as integers.
            let rankKey = [versionParts[0], versionParts.count > 1 ? versionParts[1] : 0, stabilityScore]
            if bestRankKey.isEmpty || bestRankKey.lexicographicallyPrecedes(rankKey) {
                bestRankKey = rankKey
                bestModelName = shortName
            }
        }
        guard let bestModelName else {
            // Don't cache a fallback: try listing again next time.
            return fallbackSmartModel
        }
        let chosenModel = bestModelName
        defaults.set(chosenModel, forKey: resolvedSmartModelDefaultsKey)
        defaults.set(Date(), forKey: resolvedSmartModelDateDefaultsKey)
        print("🧠 Smart model: \(chosenModel)")
        return chosenModel
    }

    private func detectImageMimeType(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4, [UInt8](imageData.prefix(4)) == pngSignature {
            return "image/png"
        }
        return "image/jpeg"
    }

    /// Sends labeled screenshots + the user's words to Gemini and returns the
    /// full reply text. `onTextChunk` is called once with the full text (the
    /// UI only shows a spinner, so token streaming isn't needed).
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        openCodeModelOverride: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        if BrainProvider.current == .opencodeGo {
            let openCodeStartTime = Date()
            do {
                let openCodeAnswer = try await openCodeGoClient.answer(
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    imageMimeType: { [weak self] imageData in self?.detectImageMimeType(for: imageData) ?? "image/jpeg" },
                    modelOverride: openCodeModelOverride
                )
                await onTextChunk(openCodeAnswer)
                return (text: openCodeAnswer, duration: Date().timeIntervalSince(openCodeStartTime))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("⚠️ OpenCode Go failed (\(error.localizedDescription)); trying Gemini")
                if KeychainStore.read(.geminiAPIKey) == nil { throw error }
            }
        }
        let startTime = Date()

        guard let apiKey = KeychainStore.read(.geminiAPIKey) else {
            throw GeminiAPIError(message: "no gemini api key yet. paste one in the orchestra menu.")
        }

        var contents: [[String: Any]] = []
        for (userText, modelText) in conversationHistory {
            contents.append(["role": "user", "parts": [["text": userText]]])
            contents.append(["role": "model", "parts": [["text": modelText]]])
        }

        var currentParts: [[String: Any]] = []
        for image in images {
            currentParts.append(["text": image.label])
            currentParts.append([
                "inline_data": [
                    "mime_type": detectImageMimeType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        currentParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentParts])

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "maxOutputTokens": 2048,
                "temperature": 0.7
            ]
        ]

        let data = try await postGenerateContentWithFallback(body: body, apiKey: apiKey, timeoutSeconds: 120)
        try Task.checkCancellation()

        let text = Self.extractText(from: data)
        guard !text.isEmpty else {
            throw GeminiAPIError(message: "gemini returned an empty answer")
        }

        await onTextChunk(text)
        return (text: text, duration: Date().timeIntervalSince(startTime))
    }

    /// Plain text-only call (used for small helper tasks like job titles).
    func generateText(systemPrompt: String, userPrompt: String) async throws -> String {
        let (text, _) = try await analyzeImageStreaming(
            images: [],
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )
        return text
    }

    /// Sends a fully-built generateContent body (used by the Mac agent for
    /// function calling) and returns the parsed JSON response.
    func generateContentRaw(body: [String: Any]) async throws -> [String: Any] {
        if BrainProvider.current == .opencodeGo {
            // No silent switch to Gemini mid agent-loop: the history is shaped for
            // DeepSeek and Gemini 3 rejects function calls without its own signatures.
            return try await openCodeGoClient.generateContentRaw(geminiBody: body)
        }
        guard let apiKey = KeychainStore.read(.geminiAPIKey) else {
            throw GeminiAPIError(message: "no gemini api key yet. paste one in the orchestra menu.")
        }
        let data = try await postGenerateContentWithFallback(body: body, apiKey: apiKey, timeoutSeconds: 180)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiAPIError(message: "gemini sent something that isn't json")
        }
        return json
    }

    // MARK: - Fallback across models

    /// Models every key can use on the free tier, tried after the requested one.
    /// On the free tier each model has its own small daily allowance (~20
    /// requests), so spreading across several multiplies what the user gets per day.
    static let reliableFallbackModels = ["gemini-3.5-flash", "gemini-3.8-flash", "gemini-2.5-flash",
                                         "gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-2.5-flash-lite"]
    private static let quotaBlockedModelsDefaultsKey = "geminiQuotaBlockedModels"

    /// Models that answered 429 "quota exceeded" recently (e.g. Pro on a free
    /// key). Skipped for 6 hours so we don't waste a round trip every time.
    private static func isQuotaBlocked(_ modelName: String) -> Bool {
        let blockedUntilByModel = UserDefaults.standard.dictionary(forKey: quotaBlockedModelsDefaultsKey) as? [String: Double] ?? [:]
        guard let blockedUntil = blockedUntilByModel[modelName] else { return false }
        return Date().timeIntervalSince1970 < blockedUntil
    }

    /// A daily-quota 429 blocks the model until tomorrow-ish (6 h); a per-minute
    /// rate-limit 429 only for 70 s.
    private static func markQuotaBlocked(_ modelName: String, errorBody: String) {
        let isDailyQuota = errorBody.contains("PerDay") || errorBody.lowercased().contains("per day")
        let blockSeconds: TimeInterval = isDailyQuota ? 6 * 60 * 60 : 70
        var blockedUntilByModel = UserDefaults.standard.dictionary(forKey: quotaBlockedModelsDefaultsKey) as? [String: Double] ?? [:]
        blockedUntilByModel[modelName] = Date().addingTimeInterval(blockSeconds).timeIntervalSince1970
        UserDefaults.standard.set(blockedUntilByModel, forKey: quotaBlockedModelsDefaultsKey)
    }

    /// Tries the requested model, then the reliable ones:
    ///  - 429 quota → remember and move on
    ///  - 500/502/503/504 "high demand" → one quick retry, then move on
    ///  - 404 unknown model → move on
    /// so a free key never gets stuck on a model it can't use.
    private func postGenerateContentWithFallback(body: [String: Any], apiKey: String, timeoutSeconds: TimeInterval) async throws -> Data {
        var candidateModels: [String] = []
        for candidateModel in [model] + Self.reliableFallbackModels where !candidateModels.contains(candidateModel) {
            candidateModels.append(candidateModel)
        }
        let usableModels = candidateModels.filter { !Self.isQuotaBlocked($0) }
        let modelsToTry = usableModels.isEmpty ? [candidateModels.last!] : usableModels
        let requestBodyData = try JSONSerialization.data(withJSONObject: body)

        var lastFailureDescription = "no model answered"
        var sawQuotaError = false
        // Never sit silent for minutes: the whole chain gets ~50 s, later tries get shorter timeouts.
        let chainDeadline = Date().addingTimeInterval(max(50, min(timeoutSeconds, 90)))
        for candidateModel in modelsToTry {
            if Date() > chainDeadline { break }
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(candidateModel):generateContent") else { continue }
            for attemptNumber in 1...2 {
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = max(10, min(timeoutSeconds, chainDeadline.timeIntervalSinceNow))
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.httpBody = requestBodyData

                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(statusCode) {
                    if candidateModel != model {
                        print("🔁 Gemini: \(model) unavailable, answered with \(candidateModel)")
                    }
                    return data
                }
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                lastFailureDescription = "\(candidateModel) said \(statusCode)"
                print("⚠️ Gemini \(candidateModel) error \(statusCode): \(errorBody.prefix(200))")

                if statusCode == 429 {
                    sawQuotaError = true
                    Self.markQuotaBlocked(candidateModel, errorBody: errorBody)
                    break
                }
                if [500, 502, 503, 504].contains(statusCode) && attemptNumber == 1 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                if [500, 502, 503, 504, 404].contains(statusCode) {
                    break
                }
                // 400/401/403: the request or key is wrong; another model won't help.
                // (Details go to the log; the message is short because it may be spoken.)
                throw GeminiAPIError(message: statusCode == 400 && errorBody.contains("API_KEY")
                                     ? "the gemini key doesn't work"
                                     : "gemini refused the request (error \(statusCode))")
            }
        }
        print("⚠️ Gemini chain failed: \(lastFailureDescription)")
        throw GeminiAPIError(message: sawQuotaError
                             ? "gemini's free daily limit is used up. adding billing in google ai studio fixes that"
                             : "gemini is too busy right now. try again in a minute")
    }

    /// Joins the text parts of the first candidate, skipping "thought" parts.
    static func extractText(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        return parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

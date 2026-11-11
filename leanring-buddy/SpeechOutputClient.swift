//
//  SpeechOutputClient.swift
//  leanring-buddy
//
//  Speaks replies. Two voices:
//    • Natural (default): Gemini text-to-speech (gemini-3.8-flash-tts) with
//      the user's own key — sounds like a person, adds about a second.
//    • Mac voice: AVSpeechSynthesizer — instant, offline, more robotic.
//  If the Gemini voice fails (no key, offline, quota), it falls back to the
//  Mac voice so Orchestra never goes silent.
//
//  Keeps the same speakText / stopPlayback / isPlaying surface as before.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechOutputClient: NSObject, ObservableObject {
    nonisolated static let naturalVoiceEnabledDefaultsKey = "useNaturalGeminiVoice"
    nonisolated static let naturalVoiceNameDefaultsKey = "naturalGeminiVoiceName"
    nonisolated static let naturalVoiceModel = "gemini-3.8-flash-tts"

    /// A few of Gemini's prebuilt voices, with Google's one-word style.
    nonisolated static let naturalVoiceOptions: [(name: String, style: String)] = [
        ("Achird", "Friendly"), ("Sulafat", "Warm"), ("Puck", "Upbeat"),
        ("Kore", "Firm"), ("Aoede", "Breezy"), ("Charon", "Informative"), ("Zephyr", "Bright")
    ]

    static var isNaturalVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: naturalVoiceEnabledDefaultsKey) as? Bool ?? true
    }

    /// The saved voice, validated so a stale name can't break every reply.
    nonisolated static var naturalVoiceName: String {
        let savedVoiceName = UserDefaults.standard.string(forKey: naturalVoiceNameDefaultsKey) ?? "Achird"
        return naturalVoiceOptions.contains(where: { $0.name == savedVoiceName }) ? savedVoiceName : "Achird"
    }

    /// Delivery style that matches each voice's character.
    nonisolated static func speakingStyle(forVoiceNamed voiceName: String) -> String {
        switch voiceName {
        case "Puck", "Zephyr": return "bright, upbeat and conversational, like an energetic friend"
        case "Kore", "Charon": return "clear, calm and confident, like a helpful expert"
        case "Aoede": return "breezy, light and easygoing"
        default: return "warm, relaxed and conversational, like a friend"
        }
    }

    /// True when the last reply had to use the Mac voice because Gemini's failed.
    @Published private(set) var lastReplyUsedMacVoiceFallback = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    /// Bumped on every new reply; an older synthesis that finishes late sees a
    /// different number and throws its audio away instead of talking over us.
    private var speechRequestGeneration = 0
    private var inFlightSynthesisTask: Task<Data, Error>?

    /// Picks the best installed English voice: premium > enhanced > default.
    private lazy var preferredMacVoice: AVSpeechSynthesisVoice? = {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let premium = englishVoices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = englishVoices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Starts speaking and returns once audio is playing.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        stopPlayback()
        speechRequestGeneration += 1
        let thisRequestGeneration = speechRequestGeneration

        lastReplyUsedMacVoiceFallback = false
        if Self.isNaturalVoiceEnabled, let apiKey = KeychainStore.read(.geminiAPIKey) {
            // Network, JSON and base64 work happen off the main actor.
            let voiceName = Self.naturalVoiceName
            let synthesisTask = Task.detached(priority: .userInitiated) {
                try await Self.synthesizeWithGemini(text: text, voiceName: voiceName, apiKey: apiKey)
            }
            inFlightSynthesisTask = synthesisTask
            do {
                // If the caller is cancelled, cancel the network request too (saves quota).
                let wavAudioData = try await withTaskCancellationHandler {
                    try await synthesisTask.value
                } onCancel: {
                    synthesisTask.cancel()
                }
                // A newer reply started (or this one was stopped) while we waited.
                guard thisRequestGeneration == speechRequestGeneration else { throw CancellationError() }
                try Task.checkCancellation()
                let player = try AVAudioPlayer(data: wavAudioData)
                audioPlayer = player
                player.play()
                lastReplyUsedMacVoiceFallback = false
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cancelled request surfaces as URLError(.cancelled), not CancellationError.
                if Task.isCancelled || synthesisTask.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard thisRequestGeneration == speechRequestGeneration else { throw CancellationError() }
                print("⚠️ Gemini voice failed, using the Mac voice: \(error.localizedDescription)")
                lastReplyUsedMacVoiceFallback = true
            }
        }
        speakWithMacVoice(text)
    }

    /// True between speakWithMacVoiceNow and the deferred speak() actually starting,
    /// so "wait until speech finishes" loops don't think it's already over.
    private var pendingMacUtteranceCount = 0

    var isPlaying: Bool {
        synthesizer.isSpeaking || (audioPlayer?.isPlaying ?? false) || pendingMacUtteranceCount > 0
    }

    func stopPlayback() {
        speechRequestGeneration += 1
        inFlightSynthesisTask?.cancel()
        inFlightSynthesisTask = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Speaks with the Mac voice right away (error messages), interruptible like any reply.
    func speakWithMacVoiceNow(_ text: String) {
        stopPlayback()
        // AVSpeechSynthesizer can drop a speak() issued right after an immediate stop,
        // so start it on the next main-loop turn.
        let generationAtRequest = speechRequestGeneration
        pendingMacUtteranceCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMacUtteranceCount -= 1
            guard self.speechRequestGeneration == generationAtRequest else { return }
            self.speakWithMacVoice(text)
        }
    }

    private func speakWithMacVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredMacVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    // MARK: - Gemini text-to-speech (Interactions API)

    nonisolated private static let synthesisSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Fall back to the Mac voice quickly rather than sit silent.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 40
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    nonisolated private static func synthesizeWithGemini(text: String, voiceName: String, apiKey: String) async throws -> Data {
        guard let interactionsURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw GeminiAPIError(message: "bad url")
        }

        let speechAnnotation: [String: Any] = ["type": "speech_metadata", "style": speakingStyle(forVoiceNamed: voiceName)]
        let textInput: [String: Any] = ["type": "text", "text": text, "annotations": [speechAnnotation]]
        let userInput: [String: Any] = ["type": "user_input", "content": [textInput]]
        let generationConfig: [String: Any] = ["speech_config": [["voice": voiceName]]]
        let body: [String: Any] = [
            "model": Self.naturalVoiceModel,
            "input": [userInput],
            "response_format": ["type": "audio"],
            "generation_config": generationConfig
        ]

        var request = URLRequest(url: interactionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await synthesisSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? ""
            throw GeminiAPIError(message: "gemini voice error \((response as? HTTPURLResponse)?.statusCode ?? 0): \(errorText.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let base64Audio = findLastAudioBase64(in: json),
              let audioData = Data(base64Encoded: base64Audio),
              !audioData.isEmpty else {
            throw GeminiAPIError(message: "gemini voice returned no audio")
        }
        // Unary responses are a full WAV file; raw PCM (24 kHz, 16-bit, mono) gets a header added.
        let startsWithRIFFHeader = audioData.prefix(4) == Data("RIFF".utf8)
        return startsWithRIFFHeader ? audioData : Self.wavFile(fromPCM16Mono24kHz: audioData)
    }

    /// The audio payload: the LAST audio block of the last model_output step
    /// (Google's documented pick), falling back to the last audio block anywhere.
    nonisolated private static func findLastAudioBase64(in json: [String: Any]) -> String? {
        if let steps = json["steps"] as? [[String: Any]] {
            for step in steps.reversed() where (step["type"] as? String) == "model_output" {
                let contentBlocks = step["content"] as? [[String: Any]] ?? []
                if let audioBlock = contentBlocks.last(where: { ($0["type"] as? String) == "audio" }),
                   let base64Data = audioBlock["data"] as? String {
                    return base64Data
                }
            }
        }
        var audioBlocksInOrder: [String] = []
        collectAudioBase64(in: json, into: &audioBlocksInOrder)
        return audioBlocksInOrder.last
    }

    nonisolated private static func collectAudioBase64(in jsonValue: Any, into audioBlocksInOrder: inout [String]) {
        if let dictionary = jsonValue as? [String: Any] {
            let typeText = (dictionary["type"] as? String ?? "") + (dictionary["mime_type"] as? String ?? "") + (dictionary["mimeType"] as? String ?? "")
            if typeText.lowercased().contains("audio"), let base64Data = dictionary["data"] as? String, base64Data.count > 100 {
                audioBlocksInOrder.append(base64Data)
            }
            for key in dictionary.keys.sorted() {
                collectAudioBase64(in: dictionary[key] as Any, into: &audioBlocksInOrder)
            }
        } else if let array = jsonValue as? [Any] {
            for nestedValue in array {
                collectAudioBase64(in: nestedValue, into: &audioBlocksInOrder)
            }
        }
    }

    nonisolated private static func wavFile(fromPCM16Mono24kHz pcmData: Data) -> Data {
        let sampleRate: UInt32 = 24_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)

        var wavData = Data()
        func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
            var littleEndianValue = value.littleEndian
            withUnsafeBytes(of: &littleEndianValue) { wavData.append(contentsOf: $0) }
        }
        wavData.append(Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcmData.count))
        wavData.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16))
        appendLittleEndian(UInt16(1))
        appendLittleEndian(channelCount)
        appendLittleEndian(sampleRate)
        appendLittleEndian(byteRate)
        appendLittleEndian(blockAlign)
        appendLittleEndian(bitsPerSample)
        wavData.append(Data("data".utf8))
        appendLittleEndian(UInt32(pcmData.count))
        wavData.append(pcmData)
        return wavData
    }
}

//
//  WakeWordListener.swift
//  leanring-buddy
//
//  "Hey Clicky" starts a Live conversation, like "Hey Siri".
//
//  How it stays private and light:
//    • Recognition runs ON THIS MAC only (Apple's on-device speech model,
//      requiresOnDeviceRecognition). If on-device recognition isn't
//      available, the wake word refuses to turn on — audio never leaves the Mac.
//    • A simple loudness gate: the recognizer is only fed sound when someone
//      is talking (plus a short lead-in), so silence costs almost nothing.
//    • Nothing is recorded or saved. Only the words "hey clicky" do anything;
//      everything else is thrown away as it's heard.
//    • It pauses while Live mode, push-to-talk or Orchestra's own voice is on.
//
//  The mic is technically open while it waits (macOS shows the orange dot):
//  that's true of any wake word, Siri included — Siri just does it on a
//  separate low-power chip that other apps can't use.
//

import AVFoundation
import Foundation
import Speech

@MainActor
final class WakeWordListener {
    var onWakeWordDetected: (() -> Void)?
    /// Short human-readable status for the menu ("listening for hey clicky", or why not).
    private(set) var statusText = "off"

    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionSessionStartDate = Date.distantPast
    private var recognitionSessionTimer: Timer?
    private let loudnessGate = WakeWordLoudnessGate()
    private(set) var isListening = false

    /// Words the recognizer might hear for "clicky".
    private static let wakePhrasePattern = #"\b(hey|hi|hay|okay|ok)\s*,?\s*(clicky|clickie|clicki|cliquey|klicky|klickie|clickey|clicky's|kliky)\b"#
    /// Recognition sessions are restarted regularly (Apple limits session length).
    private static let maximumRecognitionSessionSeconds: TimeInterval = 50

    // MARK: - Start / stop

    func startListening() {
        guard !isListening else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            statusText = "needs speech recognition permission"
            SFSpeechRecognizer.requestAuthorization { _ in }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            statusText = "needs microphone permission"
            return
        }
        guard let speechRecognizer, speechRecognizer.supportsOnDeviceRecognition else {
            // Never fall back to Apple's servers for an always-waiting mic.
            statusText = "on-device speech isn't available on this Mac, so it stays off"
            return
        }

        let newAudioEngine = AVAudioEngine()
        let inputNode = newAudioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            statusText = "no microphone found"
            return
        }
        let loudnessGate = self.loudnessGate
        loudnessGate.reset()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] audioBuffer, _ in
            // Audio thread: only pass on sound while someone is talking.
            for gatedBuffer in loudnessGate.buffersToForward(for: audioBuffer) {
                Task { @MainActor [weak self] in
                    self?.recognitionRequest?.append(gatedBuffer)
                }
            }
        }
        newAudioEngine.prepare()
        do {
            try newAudioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            statusText = "the microphone wouldn't start"
            OrchestraLog.write("👂 Wake word: mic failed to start: \(error)")
            return
        }
        audioEngine = newAudioEngine
        isListening = true
        statusText = "listening for \"hey clicky\" (on this Mac only)"
        startRecognitionSession()
        recognitionSessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartRecognitionSessionIfOld() }
        }
        OrchestraLog.write("👂 Wake word: listening (on-device)")
    }

    func stopListening(statusAfterStopping: String = "paused") {
        recognitionSessionTimer?.invalidate()
        recognitionSessionTimer = nil
        endRecognitionSession()
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
        if isListening { OrchestraLog.write("👂 Wake word: \(statusAfterStopping)") }
        isListening = false
        statusText = statusAfterStopping
    }

    // MARK: - Recognition sessions

    private func startRecognitionSession() {
        guard let speechRecognizer else { return }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .search
        newRequest.contextualStrings = ["hey clicky", "Clicky"]
        recognitionRequest = newRequest
        recognitionSessionStartDate = Date()

        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] recognitionResult, recognitionError in
            let heardText = recognitionResult?.bestTranscription.formattedString ?? ""
            let isFinal = recognitionResult?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if Self.containsWakePhrase(heardText) {
                    OrchestraLog.write("👂 Wake word: heard \"\(heardText.suffix(40))\"")
                    self.stopListening(statusAfterStopping: "heard \"hey clicky\"")
                    self.onWakeWordDetected?()
                    return
                }
                // A finished or failed session: start a fresh one (keeps memory and work small).
                if isFinal || recognitionError != nil {
                    self.endRecognitionSession()
                    self.startRecognitionSession()
                }
            }
        }
    }

    private func restartRecognitionSessionIfOld() {
        guard isListening,
              Date().timeIntervalSince(recognitionSessionStartDate) > Self.maximumRecognitionSessionSeconds,
              !loudnessGate.isSpeechOngoing else { return }
        endRecognitionSession()
        startRecognitionSession()
    }

    private func endRecognitionSession() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    static func containsWakePhrase(_ heardText: String) -> Bool {
        // Only the last few words count, so an old phrase can't fire twice.
        let lastWords = heardText.lowercased().split(separator: " ").suffix(6).joined(separator: " ")
        return lastWords.range(of: wakePhrasePattern, options: .regularExpression) != nil
    }
}

/// Passes audio on only while someone is talking: keeps ~0.5 s of lead-in so
/// the start of "hey" isn't cut, and ~1.2 s after the voice stops.
/// Runs on the audio thread, so it guards its own state with a lock.
final class WakeWordLoudnessGate: @unchecked Sendable {
    private let stateLock = NSLock()
    private var leadInBuffers: [AVAudioPCMBuffer] = []
    private var lastLoudDate = Date.distantPast
    private var isOpen = false
    /// Background noise level, learned slowly while quiet.
    private var noiseFloorLevel: Float = 0.004

    private let leadInBufferCount = 12          // ~0.5 s at 1024-frame buffers
    private let hangoverSeconds: TimeInterval = 1.2

    var isSpeechOngoing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isOpen
    }

    func reset() {
        stateLock.lock(); defer { stateLock.unlock() }
        leadInBuffers.removeAll()
        lastLoudDate = .distantPast
        isOpen = false
    }

    func buffersToForward(for audioBuffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard let bufferCopy = Self.copy(of: audioBuffer) else { return [] }
        let bufferLevel = Self.rootMeanSquare(of: bufferCopy)

        stateLock.lock(); defer { stateLock.unlock() }
        // Voice = clearly louder than the room's usual noise.
        let isLoud = bufferLevel > max(0.012, noiseFloorLevel * 3.5)
        if !isLoud && !isOpen {
            noiseFloorLevel = noiseFloorLevel * 0.98 + bufferLevel * 0.02
        }
        if isLoud { lastLoudDate = Date() }

        if isOpen {
            if !isLoud && Date().timeIntervalSince(lastLoudDate) > hangoverSeconds {
                isOpen = false
            }
            return [bufferCopy]
        }
        if isLoud {
            isOpen = true
            let buffersWithLeadIn = leadInBuffers + [bufferCopy]
            leadInBuffers.removeAll()
            return buffersWithLeadIn
        }
        leadInBuffers.append(bufferCopy)
        if leadInBuffers.count > leadInBufferCount { leadInBuffers.removeFirst() }
        return []
    }

    /// The tap reuses its buffer, so keep our own copy.
    private static func copy(of sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: sourceBuffer.format, frameCapacity: sourceBuffer.frameLength),
              let sourceChannels = sourceBuffer.floatChannelData,
              let copiedChannels = copiedBuffer.floatChannelData else { return nil }
        copiedBuffer.frameLength = sourceBuffer.frameLength
        let channelCount = Int(sourceBuffer.format.channelCount)
        let frameCount = Int(sourceBuffer.frameLength)
        for channelIndex in 0..<channelCount {
            copiedChannels[channelIndex].update(from: sourceChannels[channelIndex], count: frameCount)
        }
        return copiedBuffer
    }

    private static func rootMeanSquare(of audioBuffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = audioBuffer.floatChannelData, audioBuffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for frameIndex in 0..<Int(audioBuffer.frameLength) {
            let sample = channelData[0][frameIndex]
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(audioBuffer.frameLength)).squareRoot()
    }
}

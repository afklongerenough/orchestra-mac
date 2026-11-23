//
//  OrchestraNoteTaker.swift
//  leanring-buddy
//
//  "take notes on this": records a lecture or meeting, transcribes it live
//  with Apple Speech, and when it stops, writes a structured summary with
//  Gemini. What it records is picked in the menu (NotesAudioSource): the
//  Mac's own audio plus the mic (default), the Mac's audio only (a YouTube
//  lecture with headphones on), or the mic only (a lecture in the room).
//
//    ~/Orchestra/Notes/<date>-<slug>/audio.wav        the recording
//    ~/Orchestra/Notes/<date>-<slug>/transcript.md    everything heard
//    ~/Orchestra/Notes/<date>-<slug>/notes.md         the summary
//
//  The summary also goes to a folder the user picks in the menu — e.g. their
//  Obsidian vault (Notes destination). Without a pick it stays in ~/Orchestra.
//
//  Voice surface: [NOTES: start <topic>] / [NOTES: stop] (push-to-talk) and
//  the take_notes tool (Live). Recording caps at 2 hours. The transcript is
//  built from Apple Speech's final segments, restarting recognition whenever
//  a segment ends so long sessions keep going.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class OrchestraNoteTaker: ObservableObject {
    static let shared = OrchestraNoteTaker()

    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "off"
    @Published private(set) var recordingStartDate: Date?
    /// What's being recorded, for the menu bar indicator ("Mac + mic", "Mac audio", "Mic").
    @Published private(set) var recordingSourceLabel = "Mic"

    /// Called with a short spoken line when the notes are written.
    /// CompanionManager wires this to the same announcement queue as jobs.
    var onNotesFinishedAnnouncement: ((String) -> Void)?

    static let notesRootFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Orchestra", isDirectory: true)
        .appendingPathComponent("Notes", isDirectory: true)
    static let destinationFolderDefaultsKey = "orchestraNotesDestinationFolder"

    /// Where the finished notes.md goes: the picked folder (e.g. an Obsidian
    /// vault) or the session folder inside ~/Orchestra/Notes.
    @Published private(set) var destinationFolderURL: URL?

    func setDestinationFolder(_ folderURL: URL?) {
        UserDefaults.standard.set(folderURL?.path ?? "", forKey: Self.destinationFolderDefaultsKey)
        destinationFolderURL = folderURL
    }

    private static let maximumRecordingSeconds: TimeInterval = 2 * 60 * 60
    private static let maximumAudioByteCount = 250 * 1024 * 1024

    private var audioEngine: AVAudioEngine?
    private var audioSink: NoteAudioSink?
    private var audioMixer: NotesAudioMixer?
    private var macAudioCapture: NotesMacAudioCapture?
    private var macAudioRestartAttemptCount = 0
    private var isRestartingMacAudioCapture = false
    private var macAudioHealthCheckTask: Task<Void, Never>?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionFolderURL: URL?
    private var sessionTopicHint = ""
    private var finalizedTranscriptText = ""
    private var currentSegmentText = ""
    private var isStopping = false
    private var autoStopTask: Task<Void, Never>?
    private var consecutiveRecognitionFailures = 0

    private init() {
        if let savedPath = UserDefaults.standard.string(forKey: Self.destinationFolderDefaultsKey), !savedPath.isEmpty {
            destinationFolderURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }
    }

    /// True only when the user's OWN spoken words this turn ask for notes.
    /// A model-emitted [NOTES: start] / take_notes call is never enough on
    /// its own — recording the room's audio needs the user's clear request.
    static func userSpeechAsksToStartNotes(_ userSpeech: String) -> Bool {
        let normalizedSpeech = userSpeech.lowercased()
        let notesWordsPattern = #"\b(notes?|record|recording|transcribe|transcript)\b"#
        guard normalizedSpeech.range(of: notesWordsPattern, options: .regularExpression) != nil else { return false }
        // "stop taking notes" is a stop, not a start; nor is "don't record".
        let stopOrNegationPattern = #"\b(stop|finish|end|done|cancel|quit|don't|dont|do not|no need|never|without)\b"#
        return normalizedSpeech.range(of: stopOrNegationPattern, options: .regularExpression) == nil
    }

    // MARK: - Starting

    /// Starts recording. Returns a short status line (spoken by the caller).
    func startNotes(topicHint: String) async -> (succeeded: Bool, message: String) {
        guard !isRecording else { return (false, "already taking notes — say \"stop taking notes\" to finish") }
        let audioSource = NotesAudioSource.current
        if audioSource.usesMicrophone {
            guard await ensureMicrophonePermission() else {
                return (false, "the microphone permission is off for orchestra; turn it on in system settings, privacy and security")
            }
        }
        if audioSource.usesMacAudio && !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return (false, "recording the mac's audio needs the screen recording permission for orchestra; turn it on in system settings, privacy and security, or switch notes to mic only in the menu")
        }
        guard await ensureSpeechRecognitionPermission() else {
            return (false, "speech recognition permission is off for orchestra; turn it on in system settings, privacy and security")
        }
        let preferredLocales = [OrchestraLanguageSettings.dictationLocale, Locale.autoupdatingCurrent, Locale(identifier: "en-US")].compactMap { $0 }
        var chosenRecognizer: SFSpeechRecognizer?
        for preferredLocale in preferredLocales {
            if let recognizer = SFSpeechRecognizer(locale: preferredLocale), recognizer.isAvailable {
                chosenRecognizer = recognizer
                break
            }
        }
        guard let speechRecognizer = chosenRecognizer ?? SFSpeechRecognizer(), speechRecognizer.isAvailable else {
            return (false, "speech recognition isn't available on this mac right now")
        }
        self.speechRecognizer = speechRecognizer

        let startDate = Date()
        sessionTopicHint = topicHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = Self.sessionFolderName(date: startDate, topicHint: sessionTopicHint)
        let sessionFolderURL = Self.notesRootFolderURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionFolderURL, withIntermediateDirectories: true)
        } catch {
            return (false, "couldn't create the notes folder: \(error.localizedDescription)")
        }
        self.sessionFolderURL = sessionFolderURL
        finalizedTranscriptText = ""
        currentSegmentText = ""
        consecutiveRecognitionFailures = 0
        isStopping = false

        let newAudioSink = NoteAudioSink(maximumByteCount: Self.maximumAudioByteCount)
        audioSink = newAudioSink
        startRecognitionSegment(sink: newAudioSink)

        // Mic only keeps the original direct path; any mode with the Mac's
        // audio goes through the mixer (16 kHz mono, mic + Mac summed).
        let newAudioMixer: NotesAudioMixer? = audioSource.usesMacAudio
            ? NotesAudioMixer(mixesMacAudioIntoMicrophone: audioSource == .macAudioAndMicrophone,
                              deliverMixedBuffer: { [weak newAudioSink] mixedBuffer in newAudioSink?.append(mixedBuffer) })
            : nil
        audioMixer = newAudioMixer

        if audioSource.usesMicrophone {
            let newAudioEngine = AVAudioEngine()
            let inputNode = newAudioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                stopAudioAndRecognition()
                return (false, "no microphone input found")
            }
            let audioMixerForMicrophoneTap = newAudioMixer
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak newAudioSink] buffer, _ in
                if let audioMixerForMicrophoneTap {
                    audioMixerForMicrophoneTap.appendMicrophoneBuffer(buffer)
                } else {
                    newAudioSink?.append(buffer)
                }
            }
            do {
                newAudioEngine.prepare()
                try newAudioEngine.start()
            } catch {
                stopAudioAndRecognition()
                return (false, "the microphone wouldn't start: \(error.localizedDescription)")
            }
            audioEngine = newAudioEngine
        }

        var recordingWhatText = "the mic"
        recordingSourceLabel = "Mic"
        macAudioRestartAttemptCount = 0
        if audioSource.usesMacAudio, let newAudioMixer {
            do {
                try await startMacAudioCapture(into: newAudioMixer)
                recordingWhatText = audioSource == .macAudioOnly ? "the mac's audio" : "the mac's audio and the mic"
                recordingSourceLabel = audioSource == .macAudioOnly ? "Mac audio" : "Mac + mic"
            } catch {
                OrchestraLog.write("📝 Notes: couldn't capture the mac's audio: \(error.localizedDescription)")
                guard audioSource == .macAudioAndMicrophone else {
                    stopAudioAndRecognition()
                    return (false, "couldn't record the mac's audio (\(error.localizedDescription)); try again, or switch notes to mic only in the menu")
                }
                // Mixed mode still works from the mic alone.
                recordingWhatText = "the mic only (the mac's audio couldn't be captured)"
            }
        }

        let headerText = "# Notes — \(Self.displayDateFormatter.string(from: startDate))\n\n"
            + (sessionTopicHint.isEmpty ? "" : "Topic: \(sessionTopicHint)\n\n")
        try? headerText.write(to: sessionFolderURL.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        isRecording = true
        recordingStartDate = startDate
        if macAudioCapture != nil, let newAudioMixer {
            // Nothing from the Mac after 10 s means nothing is playing, or the
            // capture/conversion isn't working: worth a line in the log.
            macAudioHealthCheckTask = Task { [weak self, weak newAudioMixer] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, self.isRecording, let newAudioMixer else { return }
                if newAudioMixer.receivedMacAudioFrameCount == 0 {
                    OrchestraLog.write("📝 Notes: no mac audio after 10 s (nothing playing, or the capture isn't delivering)")
                }
                if let unconvertibleSummary = newAudioMixer.unconvertibleMacAudioSummary {
                    OrchestraLog.write("📝 Notes: \(unconvertibleSummary)")
                }
            }
        }
        statusText = "recording"
        // Audible cue that the mic is now being recorded (the menu bar also
        // shows a red "● Recording" indicator for the whole session).
        NSSound(named: "Pop")?.play()
        OrchestraLog.write("📝 Notes: recording started (\(folderName), \(audioSource.rawValue))")

        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumRecordingSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            OrchestraLog.write("📝 Notes: hit the 2-hour cap, stopping")
            _ = await self.stopNotes()
        }
        return (true, "taking notes from \(recordingWhatText) now — say \"stop taking notes\" when it's done")
    }

    // MARK: - Mac audio

    private func startMacAudioCapture(into audioMixer: NotesAudioMixer) async throws {
        let newMacAudioCapture = NotesMacAudioCapture(onAudioBuffer: { [weak audioMixer] macAudioBuffer in
            audioMixer?.appendMacAudioBuffer(macAudioBuffer)
        })
        newMacAudioCapture.onStoppedWithError = { [weak self] stoppedCapture, captureError in
            Task { @MainActor [weak self] in
                OrchestraLog.write("📝 Notes: mac audio capture stopped: \(captureError.localizedDescription)")
                await self?.restartMacAudioCaptureAfterStop(stoppedCapture: stoppedCapture)
            }
        }
        try await newMacAudioCapture.start()
        macAudioCapture = newMacAudioCapture
    }

    /// macOS can stop the capture mid-lecture (screen lock, display sleep,
    /// resolution change). Try to pick it back up; if that keeps failing, say
    /// so out loud instead of quietly recording nothing.
    private func restartMacAudioCaptureAfterStop(stoppedCapture: NotesMacAudioCapture) async {
        // Always make sure the stopped capture is really gone.
        await stoppedCapture.stop()
        // A late error from an old capture must not touch the current one, and
        // only one restart runs at a time.
        guard stoppedCapture === macAudioCapture, !isRestartingMacAudioCapture,
              isRecording, !isStopping, let audioMixer else { return }
        isRestartingMacAudioCapture = true
        defer { isRestartingMacAudioCapture = false }
        macAudioCapture = nil
        while isRecording && !isStopping && macAudioRestartAttemptCount < 5 {
            macAudioRestartAttemptCount += 1
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard isRecording, !isStopping else { return }
            do {
                try await startMacAudioCapture(into: audioMixer)
                // Notes stopped while it was starting: stop it again right away.
                if !isRecording || isStopping, let restartedCapture = macAudioCapture {
                    macAudioCapture = nil
                    await restartedCapture.stop()
                    return
                }
                OrchestraLog.write("📝 Notes: mac audio capture restarted")
                // Each recovered drop gets a fresh budget; only 5 failures in a row give up.
                macAudioRestartAttemptCount = 0
                return
            } catch {
                OrchestraLog.write("📝 Notes: mac audio restart \(macAudioRestartAttemptCount) failed: \(error.localizedDescription)")
            }
        }
        guard isRecording, !isStopping else { return }
        if recordingSourceLabel == "Mac audio" {
            recordingSourceLabel = "Mac audio lost"
            onNotesFinishedAnnouncement?("heads up, i lost the mac's audio for your notes. say stop taking notes and start again, or switch notes to mic only.")
        } else {
            recordingSourceLabel = "Mic"
            onNotesFinishedAnnouncement?("heads up, i lost the mac's audio, so your notes are only recording the mic now.")
        }
    }

    // MARK: - Stopping and writing

    /// Stops recording, saves audio + transcript, and writes the summary.
    func stopNotes() async -> (succeeded: Bool, message: String) {
        guard isRecording, !isStopping else { return (false, "not taking notes right now") }
        isStopping = true
        isRecording = false
        statusText = "writing notes…"
        // Audible cue that the recording has stopped.
        NSSound(named: "Glass")?.play()
        autoStopTask?.cancel()
        autoStopTask = nil

        macAudioHealthCheckTask?.cancel()
        macAudioHealthCheckTask = nil
        // Stop the Mac-audio capture and wait for it, then send out what the
        // mixer still holds, so the end of the recording isn't dropped.
        if let macAudioCapture {
            self.macAudioCapture = nil
            await macAudioCapture.stop()
        }
        audioMixer?.flushPendingMacAudio()
        // From here on nothing reaches the transcript or the WAV (so no audio
        // can be appended after endAudio), even from a capture still shutting down.
        audioMixer?.stopAcceptingAudio()
        if let unconvertibleSummary = audioMixer?.unconvertibleMacAudioSummary {
            OrchestraLog.write("📝 Notes: \(unconvertibleSummary)")
        }

        // Let Apple Speech finish the last segment before tearing down.
        audioSink?.endAudio()
        let stopWaitStartDate = Date()
        while Date().timeIntervalSince(stopWaitStartDate) < 2.0 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if currentSegmentText.isEmpty { break }
        }
        commitCurrentSegment()
        stopAudioAndRecognition()

        guard let sessionFolderURL else {
            statusText = "off"
            isStopping = false
            return (true, "notes stopped")
        }
        if let recordedPCM16Data = audioSink?.takeRecordedPCM16Data(), !recordedPCM16Data.isEmpty {
            let wavData = BuddyWAVFileBuilder.buildWAVData(fromPCM16MonoAudio: recordedPCM16Data, sampleRate: 16_000)
            try? wavData.write(to: sessionFolderURL.appendingPathComponent("audio.wav"), options: .atomic)
        }
        audioSink = nil
        let transcriptText = finalizedTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationText = recordingStartDate.flatMap { Self.durationFormatter.string(from: $0, to: Date()) } ?? ""
        recordingStartDate = nil

        guard transcriptText.count >= 40 else {
            statusText = "off"
            isStopping = false
            let savedLine = "notes stopped, but i barely heard anything — the transcript is in \(sessionFolderURL.lastPathComponent)"
            onNotesFinishedAnnouncement?(savedLine)
            return (true, savedLine)
        }

        let notesMarkdown = await summarizeTranscript(transcriptText, durationText: durationText)
        let notesFileName = "notes.md"
        try? notesMarkdown.write(to: sessionFolderURL.appendingPathComponent(notesFileName), atomically: true, encoding: .utf8)
        var savedWhereText = "~/Orchestra/Notes/\(sessionFolderURL.lastPathComponent)"
        if let destinationFolderURL,
           FileManager.default.fileExists(atPath: destinationFolderURL.path) {
            let destinationFileURL = destinationFolderURL.appendingPathComponent("\(sessionFolderURL.lastPathComponent).md")
            do {
                try notesMarkdown.write(to: destinationFileURL, atomically: true, encoding: .utf8)
                savedWhereText = destinationFolderURL.lastPathComponent
            } catch {
                OrchestraLog.write("📝 Notes: couldn't write to the picked folder: \(error.localizedDescription)")
            }
        }
        statusText = "off"
        isStopping = false
        OrchestraLog.write("📝 Notes: saved \(sessionFolderURL.lastPathComponent) (\(transcriptText.count) chars transcript)")
        let finishedLine = "your notes are saved in \(savedWhereText)"
        onNotesFinishedAnnouncement?(finishedLine)
        return (true, finishedLine)
    }

    private func summarizeTranscript(_ transcriptText: String, durationText: String) async -> String {
        let topicLine = sessionTopicHint.isEmpty ? "" : "the user called it: \(sessionTopicHint)\n"
        let systemPrompt = """
        you write clear, faithful lecture and meeting notes from a voice transcript. the transcript comes from speech recognition, so fix obvious mishearings from context but never invent content. output markdown only:
        # a short title
        ## summary — three to five sentences
        ## key points — bullets, the substance of what was said
        ## decisions — only if any were made
        ## action items — with who owns them when stated
        ## follow-ups — questions worth chasing, only if any
        skip any section that would be empty. keep it tight and useful for studying or catching up later.
        """
        let userPrompt = "\(topicLine)recorded \(Self.displayDateFormatter.string(from: Date()))\(durationText.isEmpty ? "" : ", length \(durationText)")\n\ntranscript:\n\(String(transcriptText.prefix(24_000)))"
        do {
            let smartModelName = await GeminiAPI.resolveSmartModel()
            let summaryText = try await GeminiAPI(model: smartModelName).generateText(systemPrompt: systemPrompt, userPrompt: userPrompt)
            if !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return summaryText
            }
        } catch {
            OrchestraLog.write("📝 Notes: summary failed: \(error.localizedDescription)")
        }
        return "# Notes\n\n_the summary couldn't be written just now — the full transcript is below._\n\n\(transcriptText)"
    }

    // MARK: - Recognition segments

    /// Apple Speech ends a segment after a pause or about a minute; each
    /// final (or failed) segment is committed and a fresh one starts, so a
    /// two-hour lecture keeps transcribing.
    private func startRecognitionSegment(sink: NoteAudioSink) {
        guard let speechRecognizer, isRecording || !isStopping else { return }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        sink.swapRecognitionRequest(recognitionRequest)
        recognitionTask?.cancel()
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording || self.isStopping else { return }
                if let result {
                    self.consecutiveRecognitionFailures = 0
                    self.currentSegmentText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.commitCurrentSegment()
                        if self.isRecording { self.startRecognitionSegment(sink: sink) }
                    }
                    return
                }
                if error != nil {
                    self.commitCurrentSegment()
                    guard self.isRecording else { return }
                    self.consecutiveRecognitionFailures += 1
                    if self.consecutiveRecognitionFailures > 30 {
                        OrchestraLog.write("📝 Notes: recognition keeps failing, stopping")
                        Task { _ = await self.stopNotes() }
                        return
                    }
                    // Brief pause before retrying (a no-speech error otherwise
                    // restarts in a tight loop).
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard let self, self.isRecording else { return }
                        self.startRecognitionSegment(sink: sink)
                    }
                }
            }
        }
    }

    private func commitCurrentSegment() {
        let segmentText = currentSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSegmentText = ""
        guard !segmentText.isEmpty else { return }
        finalizedTranscriptText += (finalizedTranscriptText.isEmpty ? "" : "\n\n") + segmentText
        if let sessionFolderURL {
            Self.append(segmentText + "\n\n", toFileAt: sessionFolderURL.appendingPathComponent("transcript.md"))
        }
    }

    private func stopAudioAndRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioSink?.swapRecognitionRequest(nil)
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
        if let macAudioCapture {
            Task { await macAudioCapture.stop() }
        }
        macAudioCapture = nil
        audioMixer?.stopAcceptingAudio()
        audioMixer = nil
        macAudioHealthCheckTask?.cancel()
        macAudioHealthCheckTask = nil
    }

    // MARK: - Permissions

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in continuation.resume(returning: isGranted) }
            }
        default: return false
        }
    }

    private func ensureSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
        default: return false
        }
    }

    // MARK: - Helpers

    private static func sessionFolderName(date: Date, topicHint: String) -> String {
        let datePart = folderDateFormatter.string(from: date)
        let slugSource = topicHint.isEmpty ? "notes" : topicHint
        let slug = slugSource.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(datePart)-\(String(slug.prefix(40)))"
    }

    private static func append(_ text: String, toFileAt fileURL: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(Data(text.utf8))
            try? fileHandle.close()
        } else {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static let folderDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
        return dateFormatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d 'at' HH:mm"
        return dateFormatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let componentsFormatter = DateComponentsFormatter()
        componentsFormatter.allowedUnits = [.hour, .minute]
        componentsFormatter.unitsStyle = .short
        return componentsFormatter
    }()
}

/// The audio-thread side of note recording: feeds the current recognition
/// request and accumulates 16 kHz mono PCM16 for the WAV file. Lives off the
/// main actor (the tap calls it on a real-time audio thread); a lock keeps
/// the request swap and the byte cap safe.
private final class NoteAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let pcm16Converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000)
    private var recordedPCM16Data = Data()
    private let maximumByteCount: Int

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func swapRecognitionRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        recognitionRequest = newRequest
    }

    func append(_ audioBuffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        recognitionRequest?.append(audioBuffer)
        guard recordedPCM16Data.count < maximumByteCount,
              let pcm16Chunk = pcm16Converter.convertToPCM16Data(from: audioBuffer) else { return }
        recordedPCM16Data.append(pcm16Chunk)
    }

    func endAudio() {
        lock.lock(); defer { lock.unlock() }
        recognitionRequest?.endAudio()
        // Audio after endAudio() isn't allowed; later buffers only go to the WAV.
        recognitionRequest = nil
    }

    func takeRecordedPCM16Data() -> Data {
        lock.lock(); defer { lock.unlock() }
        let takenData = recordedPCM16Data
        recordedPCM16Data = Data()
        return takenData
    }
}

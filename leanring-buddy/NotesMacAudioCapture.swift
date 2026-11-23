//
//  NotesMacAudioCapture.swift
//  leanring-buddy
//
//  Lets "take notes on this" record what the Mac itself is playing (a
//  YouTube lecture, a Zoom/Meet/Teams call), not only what the microphone
//  hears, so notes come out clean even with headphones on.
//
//  The Mac's sound comes from ScreenCaptureKit's audio capture (the same
//  Screen Recording permission Orchestra already uses for screenshots);
//  Orchestra's own voice is left out of it. In "Mac audio + mic" mode the
//  two are mixed into one 16 kHz mono stream so the user's side of a call
//  is in the notes too.
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the note taker records. Chosen in the menu (Notes → Records).
enum NotesAudioSource: String, CaseIterable, Identifiable {
    case macAudioAndMicrophone = "macAndMic"
    case macAudioOnly = "mac"
    case microphoneOnly = "mic"

    var id: String { rawValue }

    static let defaultsKey = "orchestraNotesAudioSource"

    static var current: NotesAudioSource {
        get { NotesAudioSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .macAudioAndMicrophone }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .macAudioAndMicrophone: return "Mac audio + mic"
        case .macAudioOnly: return "Mac audio only"
        case .microphoneOnly: return "Mic only"
        }
    }

    var usesMicrophone: Bool { self != .macAudioOnly }
    var usesMacAudio: Bool { self != .microphoneOnly }
}

/// Turns any PCM buffer into 16 kHz mono Float32 (one instance per source,
/// always used from that source's own thread).
final class NotesMonoResampler {
    private let targetAudioFormat: AVAudioFormat
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    init(targetAudioFormat: AVAudioFormat) {
        self.targetAudioFormat = targetAudioFormat
    }

    func convert(_ originalInputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Average the channels ourselves first: AVAudioConverter's downmix only
        // kicks in when both formats carry a channel layout, and the Mac-audio
        // format from ScreenCaptureKit usually doesn't.
        let inputBuffer = Self.averagedToMono(originalInputBuffer) ?? originalInputBuffer
        let inputFormatDescription = inputBuffer.format.settings.description
        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: targetAudioFormat)
            // Stereo → mono should mix both channels, not keep only the left one.
            audioConverter?.downmix = true
            currentInputFormatDescription = inputFormatDescription
        }
        guard let audioConverter, inputBuffer.frameLength > 0 else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetAudioFormat, frameCapacity: outputFrameCapacity) else { return nil }

        var hasProvidedInputBuffer = false
        var conversionError: NSError?
        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInputBuffer {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInputBuffer = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionStatus != .error, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }

    /// Float32 multi-channel → Float32 mono at the same sample rate, or nil if
    /// the buffer is already mono or in a layout this doesn't handle.
    private static func averagedToMono(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inputFormat = inputBuffer.format
        let channelCount = Int(inputFormat.channelCount)
        guard channelCount > 1, inputFormat.commonFormat == .pcmFormatFloat32,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: inputBuffer.frameLength),
              let monoSamples = monoBuffer.floatChannelData?[0],
              let inputChannelSamples = inputBuffer.floatChannelData else { return nil }
        let frameCount = Int(inputBuffer.frameLength)
        let channelWeight = 1 / Float(channelCount)
        if inputFormat.isInterleaved {
            // One channel pointer holding L R L R …
            let interleavedSamples = inputChannelSamples[0]
            for frameIndex in 0..<frameCount {
                var summedSample: Float = 0
                for channelIndex in 0..<channelCount { summedSample += interleavedSamples[frameIndex * channelCount + channelIndex] }
                monoSamples[frameIndex] = summedSample * channelWeight
            }
        } else {
            for frameIndex in 0..<frameCount {
                var summedSample: Float = 0
                for channelIndex in 0..<channelCount { summedSample += inputChannelSamples[channelIndex][frameIndex] }
                monoSamples[frameIndex] = summedSample * channelWeight
            }
        }
        monoBuffer.frameLength = inputBuffer.frameLength
        return monoBuffer
    }
}

/// Puts the microphone and the Mac's audio together into one 16 kHz mono
/// stream for the transcript and the WAV file.
///
/// In mixed mode the microphone is the clock: each mic buffer takes the same
/// number of Mac-audio samples that arrived meanwhile and adds them in. A
/// short backlog cap keeps the two from drifting apart over a long lecture.
final class NotesAudioMixer: @unchecked Sendable {
    static let mixedAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private static let maximumPendingMacAudioSamples = 16_000 * 2
    /// Both sides of a loud call summed at full volume would clip and distort.
    private static let mixedSourceGain: Float = 0.7

    private let lock = NSLock()
    private let microphoneResampler = NotesMonoResampler(targetAudioFormat: NotesAudioMixer.mixedAudioFormat)
    private let macAudioResampler = NotesMonoResampler(targetAudioFormat: NotesAudioMixer.mixedAudioFormat)
    private var pendingMacAudioSamples: [Float] = []
    /// How many Mac-audio frames made it through, so the note taker can tell
    /// "nothing playing / conversion failing" apart from a working capture.
    private var receivedMacAudioFrameTotal = 0
    var receivedMacAudioFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receivedMacAudioFrameTotal
    }
    private let mixesMacAudioIntoMicrophone: Bool
    private let deliverMixedBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    // @Sendable: these run on audio threads, so they must not inherit the
    // caller's main-actor isolation.
    init(mixesMacAudioIntoMicrophone: Bool, deliverMixedBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.mixesMacAudioIntoMicrophone = mixesMacAudioIntoMicrophone
        self.deliverMixedBuffer = deliverMixedBuffer
    }

    /// Called on the microphone tap's audio thread.
    func appendMicrophoneBuffer(_ microphoneBuffer: AVAudioPCMBuffer) {
        guard let resampledMicrophoneBuffer = microphoneResampler.convert(microphoneBuffer) else { return }
        if mixesMacAudioIntoMicrophone, let microphoneSamples = resampledMicrophoneBuffer.floatChannelData?[0] {
            lock.lock()
            let mixedSampleCount = min(Int(resampledMicrophoneBuffer.frameLength), pendingMacAudioSamples.count)
            for sampleIndex in 0..<mixedSampleCount {
                let summedSample = (microphoneSamples[sampleIndex] + pendingMacAudioSamples[sampleIndex]) * Self.mixedSourceGain
                microphoneSamples[sampleIndex] = max(-1, min(1, summedSample))
            }
            pendingMacAudioSamples.removeFirst(mixedSampleCount)
            lock.unlock()
        }
        deliverMixedBuffer(resampledMicrophoneBuffer)
    }

    /// Called on the ScreenCaptureKit audio queue.
    func appendMacAudioBuffer(_ macAudioBuffer: AVAudioPCMBuffer) {
        guard let resampledMacAudioBuffer = macAudioResampler.convert(macAudioBuffer) else { return }
        lock.lock()
        receivedMacAudioFrameTotal += Int(resampledMacAudioBuffer.frameLength)
        lock.unlock()
        guard mixesMacAudioIntoMicrophone else {
            deliverMixedBuffer(resampledMacAudioBuffer)
            return
        }
        guard let macAudioSamples = resampledMacAudioBuffer.floatChannelData?[0] else { return }
        lock.lock()
        pendingMacAudioSamples.append(contentsOf: UnsafeBufferPointer(start: macAudioSamples, count: Int(resampledMacAudioBuffer.frameLength)))
        if pendingMacAudioSamples.count > Self.maximumPendingMacAudioSamples {
            pendingMacAudioSamples.removeFirst(pendingMacAudioSamples.count - Self.maximumPendingMacAudioSamples)
        }
        lock.unlock()
    }

    /// On stop: Mac audio still waiting for a mic buffer goes out on its own,
    /// so the last moments of a lecture aren't lost.
    func flushPendingMacAudio() {
        lock.lock()
        let leftoverSamples = pendingMacAudioSamples
        pendingMacAudioSamples.removeAll()
        lock.unlock()
        guard !leftoverSamples.isEmpty,
              let leftoverBuffer = AVAudioPCMBuffer(pcmFormat: Self.mixedAudioFormat, frameCapacity: AVAudioFrameCount(leftoverSamples.count)),
              let leftoverChannel = leftoverBuffer.floatChannelData?[0] else { return }
        for sampleIndex in 0..<leftoverSamples.count { leftoverChannel[sampleIndex] = leftoverSamples[sampleIndex] * Self.mixedSourceGain }
        leftoverBuffer.frameLength = AVAudioFrameCount(leftoverSamples.count)
        deliverMixedBuffer(leftoverBuffer)
    }
}

/// Captures the Mac's own audio output with ScreenCaptureKit. Only an audio
/// output is attached; the (tiny, 1 fps) video frames are dropped unused.
final class NotesMacAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var stream: SCStream?
    private let sampleHandlerQueue = DispatchQueue(label: "com.orchestra.notes.mac-audio")
    private let onAudioBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    /// Called (on any thread) if macOS stops the capture, e.g. permission revoked.
    var onStoppedWithError: (@Sendable (Error) -> Void)?

    init(onAudioBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onAudioBuffer = onAudioBuffer
    }

    func start() async throws {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareableContent.displays.first else {
            throw CaptureError(message: "no display found to capture the mac's audio from")
        }
        let contentFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = true
        // Orchestra's own spoken replies stay out of the notes.
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        // Audio is all we want; keep the video side as cheap as possible.
        streamConfiguration.width = 2
        streamConfiguration.height = 2
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let newStream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        try await newStream.startCapture()
        stream = newStream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid,
              let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        onAudioBuffer(pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStoppedWithError?(error)
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        var streamDescription = streamDescriptionPointer.pointee
        guard let audioFormat = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount),
                                                                      into: pcmBuffer.mutableAudioBufferList)
        return copyStatus == noErr ? pcmBuffer : nil
    }
}

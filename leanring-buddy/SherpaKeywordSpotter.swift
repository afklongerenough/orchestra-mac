//
//  SherpaKeywordSpotter.swift
//  leanring-buddy
//
//  A real wake-word detector for "hey clicky": sherpa-onnx keyword spotting
//  (Apache-2.0, github.com/k2-fsa/sherpa-onnx) with the small English
//  zipformer KWS model (gigaspeech 3.3M). Fully offline, ~2% of one CPU
//  core, no account or key. CI downloads the library and model (pinned
//  versions + sha256) and bundles them; builds without them fall back to
//  Apple's on-device speech recognizer (see WakeWordListener).
//
//  Settings come from Hermes's tests on synthetic voices: boost 2.0 and
//  threshold 0.1 caught every "hey clicky" and none of the near-misses
//  ("hey quickly", "hey nicky", "click here"), speech or music.
//

import AVFoundation
import Foundation

#if canImport(SherpaOnnxC)
import SherpaOnnxC

final class SherpaKeywordSpotter: @unchecked Sendable {
    /// Called on the main thread when the phrase is heard.
    var onKeywordDetected: (() -> Void)?

    private let spotter: OpaquePointer
    private var stream: OpaquePointer
    /// Decoding happens here, never on the audio thread or the main thread.
    private let decodeQueue = DispatchQueue(label: "orchestra.wakeword.decode")
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let modelFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// BPE tokens for the phrase (from sherpa_onnx.text2token with this model's bpe.model).
    private static let keywordsText = "▁HE Y ▁C LI CK Y @hey_clicky\n▁HE Y ▁C LI CK I E @hey_clickie"

    /// nil if the model isn't bundled or won't load.
    init?() {
        guard let modelFolderURL = Bundle.main.resourceURL?.appendingPathComponent("kws", isDirectory: true) else { return nil }
        let encoderPath = modelFolderURL.appendingPathComponent("encoder.onnx").path
        let decoderPath = modelFolderURL.appendingPathComponent("decoder.onnx").path
        let joinerPath = modelFolderURL.appendingPathComponent("joiner.onnx").path
        let tokensPath = modelFolderURL.appendingPathComponent("tokens.txt").path
        for requiredPath in [encoderPath, decoderPath, joinerPath, tokensPath] where !FileManager.default.fileExists(atPath: requiredPath) {
            return nil
        }

        // C strings must stay alive until the spotter is created (it copies them).
        let cStrings = [encoderPath, decoderPath, joinerPath, tokensPath, "cpu", "bpe", Self.keywordsText].map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var config = SherpaOnnxKeywordSpotterConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxKeywordSpotterConfig>.size)
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(cStrings[0])
        config.model_config.transducer.decoder = UnsafePointer(cStrings[1])
        config.model_config.transducer.joiner = UnsafePointer(cStrings[2])
        config.model_config.tokens = UnsafePointer(cStrings[3])
        config.model_config.num_threads = 1
        config.model_config.provider = UnsafePointer(cStrings[4])
        config.model_config.modeling_unit = UnsafePointer(cStrings[5])
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = 2.0
        config.keywords_threshold = 0.1
        config.keywords_buf = UnsafePointer(cStrings[6])
        config.keywords_buf_size = Int32(strlen(cStrings[6]!))

        guard let createdSpotter = SherpaOnnxCreateKeywordSpotter(&config) else { return nil }
        guard let createdStream = SherpaOnnxCreateKeywordStream(createdSpotter) else {
            SherpaOnnxDestroyKeywordSpotter(createdSpotter)
            return nil
        }
        spotter = createdSpotter
        stream = createdStream
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyKeywordSpotter(spotter)
    }

    /// Call from the mic tap. Copies + resamples to 16 kHz mono, then decodes off-thread.
    func acceptMicrophoneBuffer(_ microphoneBuffer: AVAudioPCMBuffer) {
        guard let monoSamples = convertToModelSamples(microphoneBuffer), !monoSamples.isEmpty else { return }
        decodeQueue.async { [weak self] in
            self?.decode(samples: monoSamples)
        }
    }

    /// Start fresh (e.g. after a conversation), dropping anything half-heard.
    func resetStream() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            SherpaOnnxResetKeywordStream(self.spotter, self.stream)
        }
    }

    private func decode(samples: [Float]) {
        samples.withUnsafeBufferPointer { samplePointer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, samplePointer.baseAddress, Int32(samples.count))
        }
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) == 1 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let keywordResult = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            let heardKeyword = keywordResult.pointee.keyword.map { String(cString: $0) } ?? ""
            SherpaOnnxDestroyKeywordResult(keywordResult)
            if !heardKeyword.isEmpty {
                SherpaOnnxResetKeywordStream(spotter, stream)
                DispatchQueue.main.async { [weak self] in self?.onKeywordDetected?() }
            }
        }
    }

    /// Channel 0 of the mic buffer → 16 kHz mono Float32 samples.
    private func convertToModelSamples(_ microphoneBuffer: AVAudioPCMBuffer) -> [Float]? {
        guard let sourceChannels = microphoneBuffer.floatChannelData, microphoneBuffer.frameLength > 0 else { return nil }
        let sourceSampleRate = microphoneBuffer.format.sampleRate
        guard let monoSourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false),
              let monoSourceBuffer = AVAudioPCMBuffer(pcmFormat: monoSourceFormat, frameCapacity: microphoneBuffer.frameLength),
              let monoChannel = monoSourceBuffer.floatChannelData else { return nil }
        monoSourceBuffer.frameLength = microphoneBuffer.frameLength
        monoChannel[0].update(from: sourceChannels[0], count: Int(microphoneBuffer.frameLength))

        // (Re)build the converter if the mic's rate changed.
        if converterInputFormat?.sampleRate != sourceSampleRate || audioConverter == nil {
            audioConverter = AVAudioConverter(from: monoSourceFormat, to: modelFormat)
            converterInputFormat = monoSourceFormat
        }
        guard let audioConverter else { return nil }
        let outputCapacity = AVAudioFrameCount(Double(monoSourceBuffer.frameLength) * 16_000 / sourceSampleRate) + 32
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: modelFormat, frameCapacity: outputCapacity) else { return nil }
        var hasProvidedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return monoSourceBuffer
        }
        guard conversionError == nil, let convertedChannels = convertedBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: convertedChannels[0], count: Int(convertedBuffer.frameLength)))
    }
}
#endif

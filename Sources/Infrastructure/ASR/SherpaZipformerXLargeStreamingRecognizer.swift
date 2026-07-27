@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FluidAudio
import Domain
import Protocols

/// Streaming ASR engine wrapping sherpa-onnx's
/// `sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30` model —
/// a Mandarin-focused larger Zipformer transducer (int8-quantised
/// encoder + joiner, fp32 decoder), tuned for higher Chinese accuracy
/// than the older bilingual zh-en baseline at the cost of weaker
/// English coverage.
///
/// SOLID: same SRP/DIP/LSP as `SherpaOnnxStreamingRecognizer` — only
/// owns the sherpa-onnx model lifecycle, the audio→sample resampling,
/// and the polling decode loop. Differences vs the bilingual variant:
/// model files (different filenames + int8 mix) and tarball URL.
public actor SherpaZipformerXLargeStreamingRecognizer: StreamingTranscribing {

    private let logger = Logger(subsystem: "com.scribe", category: "asr.sherpa.zh-xlarge.streaming")

    nonisolated private let audioConverter: AudioConverter

    private static let tarballName = "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30"
    private static let tarballURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(tarballName).tar.bz2"
    )!

    private let downloader = SherpaTarballDownloader(
        downloadURL: SherpaZipformerXLargeStreamingRecognizer.tarballURL,
        modelName: SherpaZipformerXLargeStreamingRecognizer.tarballName
    )

    private var recognizer: SherpaOnnxRecognizer?
    private var currentUtterance: String = ""
    private var lastYieldedText: String = ""

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    /// ONNX Runtime intra-op threads for the encoder/joiner.
    ///
    /// The previous value was a literal `1`, which also happened to be the
    /// helper's default — so it carried no intent and no justification. See
    /// `ASRComputeBudget.sherpaThreadCount` for the measured basis.
    private let numThreads: Int

    public init(numThreads: Int = ASRComputeBudget.sherpaThreadCount) {
        self.audioConverter = AudioConverter(sampleRate: 16000)
        self.numThreads = numThreads
    }

    public var partials: AsyncStream<LiveCaptionUpdate> {
        get async {
            if let stream { return stream }
            let (newStream, newCont) = AsyncStream<LiveCaptionUpdate>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            self.stream = newStream
            self.continuation = newCont
            return newStream
        }
    }

    public func start() async throws {
        if recognizer != nil { return }
        let modelDir = try await downloader.ensureExtracted(
            modelDirName: Self.tarballName,
            isComplete: { dir in
                let fm = FileManager.default
                return fm.fileExists(atPath: dir.appendingPathComponent("encoder.int8.onnx").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("decoder.onnx").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("joiner.int8.onnx").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path)
            }
        )

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: modelDir.appendingPathComponent("encoder.int8.onnx").path,
            decoder: modelDir.appendingPathComponent("decoder.onnx").path,
            joiner: modelDir.appendingPathComponent("joiner.int8.onnx").path
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: modelDir.appendingPathComponent("tokens.txt").path,
            transducer: transducer,
            numThreads: numThreads
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            decodingMethod: "greedy_search"
        )

        let r = withUnsafePointer(to: &config) { SherpaOnnxRecognizer(config: $0) }
        self.recognizer = r
        self.currentUtterance = ""
        self.lastYieldedText = ""
        logger.info("sherpa-onnx zh-xlarge streaming engine ready")
    }

    public nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        let samples = try audioConverter.resampleBuffer(buffer)
        await ingest(samples: samples)
    }

    /// Flushes the trailing utterance. Earlier utterances were already
    /// delivered as final updates, so the return value is the tail only.
    public func finish() async throws -> String {
        guard let r = recognizer else { return "" }
        r.inputFinished()
        while r.isReady() { r.decode() }
        let tail = r.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)

        let cont = await ensureContinuation()
        if !tail.isEmpty {
            cont.yield(LiveCaptionUpdate(text: tail, isFinal: true))
        }
        cont.finish()

        self.continuation = nil
        self.stream = nil
        self.recognizer = nil
        self.currentUtterance = ""
        self.lastYieldedText = ""
        return tail
    }

    public func reset() async throws {
        guard let r = recognizer else { return }
        r.reset()
        currentUtterance = ""
        lastYieldedText = ""
    }

    // MARK: - Private

    /// Emits the current utterance only.
    ///
    /// This runs on **every** audio buffer — 25–50 times a second. The old
    /// version joined every committed segment into one string here, compared
    /// that against the previous full transcript, and stored another copy.
    /// Two hours in, that was roughly 150 KB rebuilt, copied and compared
    /// dozens of times per second, growing without bound for the whole
    /// session. Emitting just the utterance makes the cost constant.
    private func ingest(samples: [Float]) async {
        guard let r = recognizer else { return }
        r.acceptWaveform(samples: samples, sampleRate: 16_000)
        while r.isReady() { r.decode() }

        let text = r.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)

        if r.isEndpoint() {
            r.reset()
            currentUtterance = ""
            lastYieldedText = ""
            guard !text.isEmpty else { return }
            let cont = await ensureContinuation()
            cont.yield(LiveCaptionUpdate(text: text, isFinal: true))
            return
        }

        currentUtterance = text
        guard text != lastYieldedText else { return }
        lastYieldedText = text
        let cont = await ensureContinuation()
        cont.yield(LiveCaptionUpdate(text: text, isFinal: false))
    }

    private func ensureContinuation() async -> AsyncStream<LiveCaptionUpdate>.Continuation {
        if let continuation { return continuation }
        _ = await partials
        return continuation!
    }
}

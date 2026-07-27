@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FluidAudio
import Domain
import Protocols

/// Streaming ASR engine wrapping sherpa-onnx's
/// `sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en` —
/// non-autoregressive Paraformer covering Mandarin + Cantonese +
/// English in a shared decoder. Different architecture from the
/// Zipformer engines (no joiner; encoder + decoder only).
///
/// SOLID: same SRP/DIP/LSP as the other streaming recognizers, just a
/// different sherpa-onnx model family wired via `online.paraformer`
/// config instead of `online.transducer`.
public actor SherpaParaformerTrilingualStreamingRecognizer: StreamingTranscribing {

    private let logger = Logger(subsystem: "com.scribe", category: "asr.sherpa.paraformer-trilingual.streaming")

    nonisolated private let audioConverter: AudioConverter

    private static let tarballName = "sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en"
    private static let tarballURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(tarballName).tar.bz2"
    )!

    private let downloader = SherpaTarballDownloader(
        downloadURL: SherpaParaformerTrilingualStreamingRecognizer.tarballURL,
        modelName: SherpaParaformerTrilingualStreamingRecognizer.tarballName
    )

    private var recognizer: SherpaOnnxRecognizer?
    private var currentUtterance: String = ""
    private var lastYieldedText: String = ""

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    /// ONNX Runtime intra-op threads. See `ASRComputeBudget.sherpaThreadCount`
    /// for the measurement behind the value.
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
                    && fm.fileExists(atPath: dir.appendingPathComponent("decoder.int8.onnx").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path)
            }
        )

        let paraformer = sherpaOnnxOnlineParaformerModelConfig(
            encoder: modelDir.appendingPathComponent("encoder.int8.onnx").path,
            decoder: modelDir.appendingPathComponent("decoder.int8.onnx").path
        )
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: modelDir.appendingPathComponent("tokens.txt").path,
            paraformer: paraformer,
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
        logger.info("sherpa-onnx Paraformer zh-yue-en streaming engine ready")
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

    /// Emits the current utterance only — see the matching comment in
    /// `SherpaZipformerXLargeStreamingRecognizer.ingest` for why joining the
    /// whole session here was quadratic in session length.
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

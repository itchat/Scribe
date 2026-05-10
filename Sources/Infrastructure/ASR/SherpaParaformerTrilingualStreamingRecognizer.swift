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
    private var committedSegments: [String] = []
    private var currentUtterance: String = ""
    private var lastYieldedText: String = ""

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    public init() {
        self.audioConverter = AudioConverter(sampleRate: 16000)
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
            numThreads: 1
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
        self.committedSegments = []
        self.currentUtterance = ""
        self.lastYieldedText = ""
        logger.info("sherpa-onnx Paraformer zh-yue-en streaming engine ready")
    }

    public nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        let samples = try audioConverter.resampleBuffer(buffer)
        await ingest(samples: samples)
    }

    public func finish() async throws -> String {
        guard let r = recognizer else { return "" }
        r.inputFinished()
        while r.isReady() { r.decode() }
        commitIfNeeded(currentText: r.getResult().text)

        let final = composedTranscript()
        let cont = await ensureContinuation()
        cont.yield(LiveCaptionUpdate(text: final, isFinal: true))
        cont.finish()

        self.continuation = nil
        self.stream = nil
        self.recognizer = nil
        self.committedSegments = []
        self.currentUtterance = ""
        self.lastYieldedText = ""
        return final
    }

    public func reset() async throws {
        guard let r = recognizer else { return }
        r.reset()
        committedSegments = []
        currentUtterance = ""
        lastYieldedText = ""
    }

    // MARK: - Private

    private func ingest(samples: [Float]) async {
        guard let r = recognizer else { return }
        r.acceptWaveform(samples: samples, sampleRate: 16_000)
        while r.isReady() { r.decode() }
        currentUtterance = r.getResult().text
        if r.isEndpoint() {
            commitIfNeeded(currentText: currentUtterance)
            r.reset()
            currentUtterance = ""
        }
        let combined = composedTranscript()
        if combined != lastYieldedText {
            lastYieldedText = combined
            let cont = await ensureContinuation()
            cont.yield(LiveCaptionUpdate(text: combined))
        }
    }

    private func commitIfNeeded(currentText: String) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedSegments.append(trimmed)
    }

    private func composedTranscript() -> String {
        let trimmedCurrent = currentUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrent.isEmpty {
            return committedSegments.joined(separator: " ")
        }
        if committedSegments.isEmpty {
            return trimmedCurrent
        }
        return committedSegments.joined(separator: " ") + " " + trimmedCurrent
    }

    private func ensureContinuation() async -> AsyncStream<LiveCaptionUpdate>.Continuation {
        if let continuation { return continuation }
        _ = await partials
        return continuation!
    }
}

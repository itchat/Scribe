@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FluidAudio
import Domain
import Protocols

/// Streaming ASR engine wrapping sherpa-onnx's `SherpaOnnxRecognizer` loaded
/// with the bilingual `sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20`
/// model — true streaming (cache-aware Zipformer transducer with frame-sync
/// online decoding) and a single bilingual decoder + shared BPE/char vocab,
/// so intra-utterance Mandarin↔English code-switching works natively
/// (e.g. "今天 deploy 一个 new feature 到 production").
///
/// SRP: only owns the sherpa-onnx model lifecycle, the audio→sample
///      resampling, and the polling decode loop that translates
///      partial/endpointed transcripts into `LiveCaptionUpdate`s.
/// DIP: callers see only `StreamingTranscribing`, not sherpa-onnx internals.
/// LSP: behaves identically to the other `StreamingTranscribing` engines —
///      cumulative monotonic partial text within a session, one final
///      `isFinal=true` emission on `finish()`.
public actor SherpaOnnxStreamingRecognizer: StreamingTranscribing {

    private let logger = Logger(subsystem: "com.scribe", category: "asr.sherpa.zh-en.streaming")

    /// `nonisolated` so AVAudioPCMBuffer (non-Sendable) doesn't have to
    /// cross the actor boundary on entry — same Sendable pattern as the
    /// other recognizers in this module. AudioConverter is documented as
    /// stateless ("creates a new AVAudioConverter for each operation").
    nonisolated private let audioConverter: AudioConverter

    private let downloader: SherpaModelDownloader

    /// sherpa-onnx native recognizer (not `Sendable`; isolated to this
    /// actor's executor for safety). `nil` until `start()`.
    private var recognizer: SherpaOnnxRecognizer?

    /// Accumulator for endpointed segments — each utterance the engine
    /// has finished decoding gets appended here, freeing the engine to
    /// `reset()` and start a fresh decoding state without losing the
    /// monotonic transcript view our protocol promises callers.
    private var committedSegments: [String] = []
    private var currentUtterance: String = ""
    private var lastYieldedText: String = ""

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    public init(downloader: SherpaModelDownloader = SherpaModelDownloader()) {
        // Bilingual zh-en Zipformer expects 16 kHz mono Float32, matching
        // FluidAudio's default — single shared resampler instance is fine
        // because AudioConverter creates a fresh AVAudioConverter per call.
        self.audioConverter = AudioConverter(sampleRate: 16000)
        self.downloader = downloader
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

        let model = try await downloader.ensureAvailable()

        // Build config exactly matching the upstream decode-file.swift
        // template for this model. enableEndpoint=true gives us a chance
        // to commit utterances and reset decoder state mid-session
        // instead of letting the lattice grow unbounded.
        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: model.encoderPath.path,
            decoder: model.decoderPath.path,
            joiner: model.joinerPath.path
        )
        // Match upstream `swift-api-examples/decode-file.swift` exactly —
        // they leave `modelType` at the default empty string. Setting it
        // to "zipformer" caused `SherpaOnnxCreateOnlineRecognizer` to
        // return nil and the wrapper to segfault on the next line.
        let modelConfig = sherpaOnnxOnlineModelConfig(
            tokens: model.tokensPath.path,
            transducer: transducer,
            numThreads: 1
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var config = sherpaOnnxOnlineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            enableEndpoint: true,
            decodingMethod: "greedy_search"
        )

        // C API takes config by pointer — withUnsafePointer keeps the
        // struct's lifetime well-defined for the duration of the call.
        let r = withUnsafePointer(to: &config) { SherpaOnnxRecognizer(config: $0) }
        self.recognizer = r
        self.committedSegments = []
        self.currentUtterance = ""
        self.lastYieldedText = ""

        logger.info("sherpa-onnx zh-en streaming engine ready")
    }

    public nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        // Resample 48 kHz stereo → 16 kHz mono Float32 in the caller's
        // isolation, then hop the Sendable [Float] into the actor.
        let samples = try audioConverter.resampleBuffer(buffer)
        await ingest(samples: samples)
    }

    public func finish() async throws -> String {
        guard let r = recognizer else { return "" }

        r.inputFinished()
        // Drain remaining frames so the final partial reflects all input.
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

        // Endpoint = utterance boundary (long enough trailing silence per
        // rule1/2/3 above). Move the utterance into the committed history
        // and let the recognizer start a fresh decoding state — keeps the
        // model accurate over long sessions without losing past text.
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

    /// Concatenates committed utterances + the in-progress one so callers
    /// see a stable monotonic transcript across endpoint boundaries.
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
        _ = await partials  // forces lazy creation
        return continuation!
    }
}

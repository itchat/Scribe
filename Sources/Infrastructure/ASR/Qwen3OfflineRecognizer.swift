import Foundation
import AVFoundation
import os
import Domain
import Protocols
import Qwen3ASR

/// Offline batch ASR powered by Qwen3-ASR (0.6B or 1.7B) running on Apple
/// Silicon via MLX-Swift. Used by the burn pipeline to transcribe a video's
/// extracted audio track when the user picks a Qwen3 engine in Settings.
///
/// SOLID:
/// - **SRP**: Only converts an audio file to a `TranscriptionResult`. No UI,
///   no model-lifecycle UI, no progress UI formatting beyond passthrough.
/// - **DIP**: Implements `SpeechRecognizing`; the pipeline depends on the
///   protocol, not this concrete class. Drop-in replaceable with
///   `FluidAudioRecognizer`.
/// - **LSP**: Returns the same `TranscriptionResult` shape (text + segments)
///   as `FluidAudioRecognizer`, so downstream `SubtitleFormatter` is
///   indifferent to which recognizer produced it.
/// - **actor**: serialises access to the non-thread-safe `Qwen3ASRModel`.
public actor Qwen3OfflineRecognizer: SpeechRecognizing {

    /// Which Qwen3-ASR variant to load. The MLX 4-bit checkpoints from
    /// HuggingFace `aufklarer/...` are the smallest viable form factor and
    /// match the IDs used by speech-swift's CLI in their batch examples.
    public enum Size: Sendable {
        case b0_6
        case b1_7

        public var modelId: String {
            switch self {
            case .b0_6: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            case .b1_7: return "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
            }
        }

        public var label: String {
            switch self {
            case .b0_6: return "0.6B"
            case .b1_7: return "1.7B"
            }
        }
    }

    private let size: Size
    private var model: Qwen3ASRModel?
    private var aligner: Qwen3ForcedAligner?
    private let logger = Logger(subsystem: "com.scribe", category: "asr.qwen3.offline")

    public init(size: Size) {
        self.size = size
    }

    // MARK: - SpeechRecognizing

    public func transcribe(
        audioAt url: URL,
        progress: (any Protocols.ProgressReporting)?
    ) async throws -> TranscriptionResult {
        let asrModel = try await ensureASRModelLoaded(progress: progress)

        progress?.reportStatus("Transcribing with Qwen3-ASR \(size.label)…")
        let (samples, duration) = try Self.readAudio16kMono(at: url)

        // Qwen3ASRModel.transcribe is synchronous and not thread-safe —
        // actor isolation guarantees serialised access, and we keep the
        // call on this actor's executor (no `await` between sample read
        // and decode).
        let text = asrModel.transcribe(audio: samples, sampleRate: 16000, language: nil)
        logger.info("Qwen3 \(self.size.label, privacy: .public) emitted \(text.count, privacy: .public) chars over \(duration, format: .fixed(precision: 2), privacy: .public)s audio")

        // Align text → audio for word-level acoustic timestamps. Falls
        // back to char-weighted heuristic if alignment fails or returns
        // empty so we never ship a cueless SRT.
        let segments = await alignedSegments(samples: samples, text: text, duration: duration, progress: progress)
        return TranscriptionResult(text: text, segments: segments)
    }

    // MARK: - Private

    private func ensureASRModelLoaded(
        progress: (any Protocols.ProgressReporting)?
    ) async throws -> Qwen3ASRModel {
        if let model { return model }

        let label = size.label
        progress?.reportStatus("Loading Qwen3-ASR \(label) (first run downloads ~\(size == .b0_6 ? "342 MB" : "700 MB"))…")
        logger.info("Loading Qwen3-ASR \(label, privacy: .public): \(self.size.modelId, privacy: .public)")

        let captured = size  // avoid capturing self in the C-style closure
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: size.modelId,
            cacheDir: nil,
            offlineMode: false,
            progressHandler: { [weak progress] fraction, message in
                let percent = Int(fraction * 100)
                progress?.reportStatus("Qwen3-ASR \(captured.label): \(message) \(percent)%")
            }
        )
        self.model = loaded
        logger.info("Qwen3-ASR \(label, privacy: .public) ready")
        return loaded
    }

    /// Lazy-load Qwen3-ForcedAligner-0.6B. ~342 MB extra first-run download
    /// shared across all Qwen3 ASR sizes (4-bit MLX checkpoint). Loaded on
    /// demand so users that never start a transcription don't pay the cost.
    private func ensureAlignerLoaded(
        progress: (any Protocols.ProgressReporting)?
    ) async -> Qwen3ForcedAligner? {
        if let aligner { return aligner }

        progress?.reportStatus("Loading word-timing aligner (first run downloads ~342 MB)…")
        do {
            let loaded = try await Qwen3ForcedAligner.fromPretrained(
                modelId: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit",
                cacheDir: nil,
                offlineMode: false,
                progressHandler: { [weak progress] fraction, message in
                    let percent = Int(fraction * 100)
                    progress?.reportStatus("Aligner: \(message) \(percent)%")
                }
            )
            self.aligner = loaded
            logger.info("Qwen3-ForcedAligner ready")
            return loaded
        } catch {
            // Degrade gracefully — char-weighted chunker still produces a
            // usable SRT, just without acoustic word boundaries.
            logger.error("Aligner load failed; falling back to char-weighted chunker: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func alignedSegments(
        samples: [Float],
        text: String,
        duration: Double,
        progress: (any Protocols.ProgressReporting)?
    ) async -> [Domain.TranscriptionSegment] {
        let language = Self.detectLanguage(text)

        guard let aligner = await ensureAlignerLoaded(progress: progress) else {
            return Self.makeFallbackSegments(text: text, duration: duration)
        }

        progress?.reportStatus("Aligning word-level timestamps…")
        let words = aligner.align(audio: samples, text: text, sampleRate: 16000, language: language)
        guard !words.isEmpty else {
            logger.warning("Aligner returned no words — falling back to char-weighted chunker")
            return Self.makeFallbackSegments(text: text, duration: duration)
        }
        logger.info("Aligner produced \(words.count, privacy: .public) word timestamps")
        return WordGroupingChunker.makeSegments(words: words)
    }

    /// Crude CJK ratio heuristic. The aligner accepts an open-ended
    /// `String?` language hint; "Chinese" vs "English" steers its word
    /// splitter (CJK chars vs whitespace tokenisation). Other languages
    /// fall back to "English" for now — extend if Spanish/Japanese
    /// transcripts start showing up in real workloads.
    private static func detectLanguage(_ text: String) -> String {
        var cjkCount = 0
        var totalNonSpace = 0
        for scalar in text.unicodeScalars {
            if !scalar.properties.isWhitespace {
                totalNonSpace += 1
            }
            // CJK Unified Ideographs + Extension A
            if (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        guard totalNonSpace > 0 else { return "English" }
        return Double(cjkCount) / Double(totalNonSpace) > 0.3 ? "Chinese" : "English"
    }

    /// Read a 16 kHz mono Float32 sample buffer from disk. The pipeline's
    /// `FFmpegAudioExtractor` already writes 16k mono WAV (`-ar 16000 -ac 1`),
    /// so AVAudioFile's processingFormat lands on Float32 and we just copy
    /// the channel data out.
    private static func readAudio16kMono(at url: URL) throws -> (samples: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else {
            throw ScribeError.audioFileNotFound(url)
        }
        try file.read(into: buffer)

        let duration = Double(file.length) / file.processingFormat.sampleRate

        // FFmpeg outputs mono PCM s16le → AVAudioFile converts to Float32 on
        // read, so floatChannelData is the canonical path. If a future
        // extraction format ever returns int data, we'd need a converter
        // here, but right now the contract is fixed.
        guard let floatChannels = buffer.floatChannelData else {
            throw ScribeError.audioExtractionFailed(
                underlying: NSError(
                    domain: "Qwen3OfflineRecognizer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Extracted audio at \(url.lastPathComponent) is not Float32 PCM"]
                )
            )
        }
        let samples = Array(UnsafeBufferPointer(start: floatChannels[0], count: Int(buffer.frameLength)))
        return (samples, duration)
    }

    /// Char-weighted fallback used when the aligner is unavailable or
    /// returns empty. See `SentenceChunker` for the policy.
    private static func makeFallbackSegments(text: String, duration: Double) -> [Domain.TranscriptionSegment] {
        SentenceChunker.makeSegments(text: text, duration: duration)
    }
}

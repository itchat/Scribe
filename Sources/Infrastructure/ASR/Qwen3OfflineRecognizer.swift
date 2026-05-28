import Foundation
import AVFoundation
import os
import MLX
import Domain
import Protocols
import Qwen3ASR
import SpeechVAD
import AudioCommon

/// Offline batch ASR powered by Qwen3-ASR (0.6B or 1.7B) running on Apple
/// Silicon via MLX-Swift. Used by the burn pipeline to transcribe a video's
/// extracted audio track when the user picks a Qwen3 engine in Settings.
///
/// Implementation note (long-video fix): Qwen3-ASR's encoder was trained on
/// 30 s windows; speech-swift's `WhisperFeatureExtractor` hard-caps input at
/// 1200 s of mel frames and the decoder caps output at `maxTokens` (default
/// 448). Passing a multi-hour audio in a single `transcribe()` call therefore
/// truncates the audio AND the output, producing the "near-empty SRT" bug.
/// We now mirror speech-swift's own `StreamingASR` strategy: run Silero VAD
/// over the samples, transcribe each speech run separately (force-split at
/// 25 s so a runaway speaker stays inside the encoder's comfort zone), and
/// stitch the results with VAD-derived timestamps.
///
/// SOLID:
/// - **SRP**: Only converts an audio file to a `TranscriptionResult`. The
///   chunk-boundary state machine lives in `Qwen3SegmentPlanner`; audio I/O
///   in `AudioFileReader`; cue subdivision in `SentenceChunker`.
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

    // MARK: - Tunables
    //
    // 25 s sits comfortably below the encoder's 30 s training context;
    // VAD typically force-splits well before this, but `maxSegmentDuration`
    // is the hard ceiling that prevents a sustained speaker (e.g. a
    // monologue lecture) from feeding the model a 5-minute slice.
    private static let sampleRate: Int = 16_000
    private static let maxSegmentDuration: Float = 25.0
    private static let segmentMaxTokens: Int = 448

    private let size: Size
    private var model: Qwen3ASRModel?
    private var vad: SileroVADModel?
    private let logger = Logger(subsystem: "com.scribe", category: "asr.qwen3.offline")

    public init(size: Size) {
        self.size = size
    }

    // MARK: - SpeechRecognizing

    public func transcribe(
        audioAt url: URL,
        progress: (any Protocols.ProgressReporting)?
    ) async throws -> Domain.TranscriptionResult {
        let asrModel = try await ensureASRModelLoaded(progress: progress)
        let vadModel = try await ensureVADLoaded(progress: progress)

        progress?.reportStatus("Transcribing with Qwen3-ASR \(size.label)…")
        let (samples, duration) = try AudioFileReader.readMono16k(at: url)
        let totalSamples = samples.count

        // VAD-based chunking — drive `StreamingVADProcessor` over the whole
        // file in 512-sample increments, harvest its events through
        // `Qwen3SegmentPlanner`, and transcribe each boundary individually.
        let segments = await transcribeChunked(
            model: asrModel,
            vadModel: vadModel,
            samples: samples,
            duration: duration,
            progress: progress
        )

        // Glue per-utterance transcripts into one document. We use a space
        // for whitespace-separated languages; Qwen3-ASR emits CJK
        // punctuation natively so consecutive Chinese utterances stay
        // visually contiguous without additional separators.
        let fullText = segments
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        logger.info("Qwen3 \(self.size.label, privacy: .public) produced \(segments.count, privacy: .public) cues over \(duration, format: .fixed(precision: 2), privacy: .public)s audio (\(totalSamples, privacy: .public) samples)")
        return Domain.TranscriptionResult(text: fullText, segments: segments)
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

    private func ensureVADLoaded(
        progress: (any Protocols.ProgressReporting)?
    ) async throws -> SileroVADModel {
        if let vad { return vad }
        progress?.reportStatus("Loading Silero VAD for chunking (first run downloads ~40 MB)…")
        let loaded = try await SileroVADModel.fromPretrained()
        self.vad = loaded
        logger.info("Silero VAD ready for Qwen3 offline chunking")
        return loaded
    }

    /// Drive the VAD over `samples` in 512-sample frames, transcribing each
    /// utterance the planner emits. Returns segments in chronological order
    /// with sub-cue subdivision via `SentenceChunker` so a long utterance
    /// becomes multiple readable SRT cues instead of one wall of text.
    private func transcribeChunked(
        model: Qwen3ASRModel,
        vadModel: SileroVADModel,
        samples: [Float],
        duration: Double,
        progress: (any Protocols.ProgressReporting)?
    ) async -> [Domain.TranscriptionSegment] {
        let processor = StreamingVADProcessor(model: vadModel)
        var planner = Qwen3SegmentPlanner(maxSegmentDuration: Self.maxSegmentDuration)
        var collected: [Domain.TranscriptionSegment] = []
        var transcribedSeconds: Float = 0
        var finalsSinceCacheFlush = 0

        let chunkSize = SileroVADModel.chunkSize
        let totalSamples = samples.count
        var offset = 0

        while offset < totalSamples {
            let end = min(offset + chunkSize, totalSamples)
            let chunk = Array(samples[offset ..< end])
            let events = processor.process(samples: chunk)

            for event in events {
                if let boundary = planner.handle(event) {
                    let cues = await transcribeBoundary(
                        model: model,
                        boundary: boundary,
                        samples: samples
                    )
                    collected.append(contentsOf: cues)
                    transcribedSeconds = boundary.endTime
                    finalsSinceCacheFlush += 1
                    if finalsSinceCacheFlush >= 8 {
                        finalsSinceCacheFlush = 0
                        MLX.Memory.clearCache()
                    }
                }
            }

            // Force-split runaway utterances *between* VAD chunks so the
            // model never sees > maxSegmentDuration of audio.
            if let split = planner.checkForceSplit(at: processor.currentTime) {
                let cues = await transcribeBoundary(
                    model: model,
                    boundary: split,
                    samples: samples
                )
                collected.append(contentsOf: cues)
                transcribedSeconds = split.endTime
            }

            // Progress: percent of audio seconds processed. Refresh every
            // ~5 s of audio to keep the status bar from thrashing.
            if duration > 0 {
                let pct = Int((Double(processor.currentTime) / duration) * 100.0)
                progress?.reportStatus("Transcribing with Qwen3-ASR \(size.label)… \(min(99, pct))%")
            }

            offset = end
        }

        // Flush: close VAD's internal state machine + any leftover speech.
        let flushed = processor.flush()
        for event in flushed {
            if let boundary = planner.handle(event) {
                let cues = await transcribeBoundary(
                    model: model,
                    boundary: boundary,
                    samples: samples
                )
                collected.append(contentsOf: cues)
                transcribedSeconds = boundary.endTime
            }
        }
        if let tail = planner.flush(at: Float(duration)) {
            let cues = await transcribeBoundary(
                model: model,
                boundary: tail,
                samples: samples
            )
            collected.append(contentsOf: cues)
            transcribedSeconds = tail.endTime
        }

        _ = transcribedSeconds  // logged via segment count above
        MLX.Memory.clearCache()
        return collected
    }

    /// Slice `samples[range]`, transcribe, and subdivide the result into
    /// reading-shaped cues with timestamps proportional to the slice.
    private func transcribeBoundary(
        model: Qwen3ASRModel,
        boundary: Qwen3SegmentBoundary,
        samples: [Float]
    ) async -> [Domain.TranscriptionSegment] {
        let range = boundary.sampleRange(sampleRate: Self.sampleRate, totalSamples: samples.count)
        guard range.upperBound > range.lowerBound else { return [] }

        let slice = Array(samples[range])
        // Qwen3ASRModel.transcribe is synchronous and not thread-safe —
        // actor isolation guarantees serialised access here.
        let raw = model.transcribe(
            audio: slice,
            sampleRate: Self.sampleRate,
            language: nil,
            maxTokens: Self.segmentMaxTokens,
            context: nil
        )
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Map the slice-relative cues that `SentenceChunker` produces back
        // into the absolute timeline by anchoring them at `boundary.startTime`.
        let sliceDuration = Double(boundary.duration)
        let sliceSegments = SentenceChunker.makeSegments(text: text, duration: sliceDuration)
        let anchor = Double(boundary.startTime)
        return sliceSegments.map { sub in
            Domain.TranscriptionSegment(
                text: sub.text,
                start: anchor + sub.start,
                end: anchor + sub.end
            )
        }
    }
}

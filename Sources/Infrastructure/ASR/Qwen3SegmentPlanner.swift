import Foundation
import AudioCommon
import SpeechVAD

/// Time-range describing a span of audio that should be transcribed as one
/// model call. Produced by `Qwen3SegmentPlanner` from incoming VAD events
/// and consumed by `Qwen3OfflineRecognizer` to slice `[Float]` samples.
///
/// SOLID:
/// - **SRP**: pure value type — start/end + a single derived sample-index
///   helper. No I/O, no model state.
public struct Qwen3SegmentBoundary: Sendable, Equatable {
    public let startTime: Float
    public let endTime: Float

    public init(startTime: Float, endTime: Float) {
        self.startTime = startTime
        self.endTime = endTime
    }

    public var duration: Float { endTime - startTime }

    /// Convert this seconds-based boundary to a `samples[lower..<upper]`
    /// range clamped to the supplied total length, so callers never slice
    /// past the end of the buffer when VAD timestamps lag the sample cursor.
    public func sampleRange(sampleRate: Int, totalSamples: Int) -> Range<Int> {
        let lower = max(0, min(totalSamples, Int(Float(sampleRate) * startTime)))
        let upper = max(lower, min(totalSamples, Int(Float(sampleRate) * endTime)))
        return lower ..< upper
    }
}

/// Stateful state machine that converts a stream of `VADEvent`s into
/// model-sized `Qwen3SegmentBoundary` slices.
///
/// Why a planner instead of inlining the logic: Qwen3-ASR's encoder was
/// trained on ≤30 s windows; feeding hours of audio in one shot makes the
/// decoder emit EOS almost immediately, producing the "near-empty SRT"
/// long-video bug. The planner enforces:
///
/// 1. **VAD boundaries** as the primary chunking signal — utterances become
///    natural SRT cues without cutting words in half.
/// 2. **Force-split** for runaway speech longer than `maxSegmentDuration`
///    so a sustained speaker never exceeds the model's training context.
///
/// SOLID:
/// - **SRP**: only boundary planning. No model invocation, no audio I/O,
///   no SRT formatting.
/// - **OCP**: tunables exposed as init parameters so an Apple Watch / iPad
///   build with tighter context budgets can lower `maxSegmentDuration`
///   without touching the algorithm.
/// - **DIP**: takes raw `VADEvent`s, knows nothing about Silero or how the
///   events were produced; testable with synthetic event sequences.
///
/// Not thread-safe by design — caller drives it serially from one VAD
/// processing loop. The `Qwen3OfflineRecognizer` and
/// `Qwen3ASRStreamingRecognizer` actors provide that serialisation.
public struct Qwen3SegmentPlanner {

    /// Mirror of `StreamingASRConfig.maxSegmentDuration` from speech-swift.
    /// 25 s sits comfortably below the 30 s encoder training context while
    /// still being large enough that natural utterances rarely hit it.
    public var maxSegmentDuration: Float

    private var currentStart: Float?

    public init(maxSegmentDuration: Float = 25.0) {
        self.maxSegmentDuration = maxSegmentDuration
        self.currentStart = nil
    }

    /// Process one VAD event. Returns a completed boundary if the event
    /// closes an utterance, or `nil` if the event only transitions state.
    public mutating func handle(_ event: VADEvent) -> Qwen3SegmentBoundary? {
        switch event {
        case .speechStarted(let time):
            currentStart = time
            return nil
        case .speechEnded(let segment):
            guard let start = currentStart else {
                // Unbalanced — VAD emitted an ended event without a
                // matching started (can happen on flush after a force
                // split). Drop it; the force split already produced
                // the boundary.
                return nil
            }
            currentStart = nil
            guard segment.endTime > start else { return nil }
            return Qwen3SegmentBoundary(startTime: start, endTime: segment.endTime)
        }
    }

    /// Force-split a runaway utterance that has been ongoing past
    /// `maxSegmentDuration`. Caller should invoke this every chunk while
    /// `currentStart != nil`. Returns the split boundary and rolls the
    /// internal `currentStart` so the *next* boundary picks up where this
    /// one left off — i.e. continued speech is not lost.
    public mutating func checkForceSplit(at currentTime: Float) -> Qwen3SegmentBoundary? {
        guard let start = currentStart,
              currentTime - start >= maxSegmentDuration else {
            return nil
        }
        currentStart = currentTime
        return Qwen3SegmentBoundary(startTime: start, endTime: currentTime)
    }

    /// Close any in-flight speech at the end of the stream so a final
    /// utterance that ran into EOF is still transcribed.
    public mutating func flush(at endTime: Float) -> Qwen3SegmentBoundary? {
        guard let start = currentStart, endTime > start else {
            currentStart = nil
            return nil
        }
        currentStart = nil
        return Qwen3SegmentBoundary(startTime: start, endTime: endTime)
    }
}

import Testing
import Foundation
import AudioCommon
import SpeechVAD
@testable import Domain
@testable import Infrastructure

/// Pure-logic tests for the VAD-driven segment planner that
/// `Qwen3OfflineRecognizer` uses to chunk long audio into model-sized slices
/// (Qwen3-ASR encoder was trained on 30 s windows; feeding multi-hour audio
/// in one shot collapses output to near-empty). These tests exercise the
/// planner state machine without loading any model weights.
@Suite("Qwen3SegmentPlanner")
struct Qwen3SegmentPlannerTests {

    private func segment(_ start: Float, _ end: Float) -> SpeechSegment {
        SpeechSegment(startTime: start, endTime: end)
    }

    // MARK: - VAD-driven boundaries

    @Test("Single speechEnded after speechStarted emits one boundary")
    func singleSegment() {
        var planner = Qwen3SegmentPlanner()
        var boundaries: [Qwen3SegmentBoundary] = []
        boundaries += planner.handle(.speechStarted(time: 1.0)).map { [$0] } ?? []
        boundaries += planner.handle(.speechEnded(segment: segment(1.0, 4.0))).map { [$0] } ?? []
        #expect(boundaries.count == 1)
        #expect(abs(boundaries[0].startTime - 1.0) < 0.001)
        #expect(abs(boundaries[0].endTime - 4.0) < 0.001)
    }

    @Test("Silence between two utterances yields two distinct boundaries")
    func twoSegments() {
        var planner = Qwen3SegmentPlanner()
        var boundaries: [Qwen3SegmentBoundary] = []
        _ = planner.handle(.speechStarted(time: 0.5))
        if let b = planner.handle(.speechEnded(segment: segment(0.5, 2.0))) { boundaries.append(b) }
        _ = planner.handle(.speechStarted(time: 5.0))
        if let b = planner.handle(.speechEnded(segment: segment(5.0, 8.0))) { boundaries.append(b) }
        #expect(boundaries.count == 2)
        #expect(abs(boundaries[0].endTime - 2.0) < 0.001)
        #expect(abs(boundaries[1].startTime - 5.0) < 0.001)
    }

    @Test("speechEnded without prior speechStarted is dropped")
    func unbalancedEndedIgnored() {
        var planner = Qwen3SegmentPlanner()
        let result = planner.handle(.speechEnded(segment: segment(0.0, 1.0)))
        #expect(result == nil)
    }

    // MARK: - Force-split for long speech runs

    @Test("Speech longer than maxSegmentDuration triggers a force-split boundary")
    func forceSplitOnLongSpeech() {
        var planner = Qwen3SegmentPlanner(maxSegmentDuration: 10.0)
        _ = planner.handle(.speechStarted(time: 0.0))
        // No force-split until the time exceeds the threshold.
        #expect(planner.checkForceSplit(at: 5.0) == nil)
        // At 11s we should force-split.
        guard let split = planner.checkForceSplit(at: 11.0) else {
            Issue.record("Expected force-split at 11s with maxSegmentDuration=10s")
            return
        }
        #expect(abs(split.startTime - 0.0) < 0.001)
        #expect(abs(split.endTime - 11.0) < 0.001)
    }

    @Test("Force-split rolls the speechStart so a continuing utterance keeps emitting")
    func forceSplitResetsStart() {
        var planner = Qwen3SegmentPlanner(maxSegmentDuration: 10.0)
        _ = planner.handle(.speechStarted(time: 0.0))
        _ = planner.checkForceSplit(at: 11.0)  // first split
        // Subsequent VAD-ended event should give us the *second* chunk
        // starting from the split point, not from 0.
        guard let final = planner.handle(.speechEnded(segment: segment(11.0, 14.0))) else {
            Issue.record("Expected a final boundary after force-split")
            return
        }
        #expect(abs(final.startTime - 11.0) < 0.001)
        #expect(abs(final.endTime - 14.0) < 0.001)
    }

    @Test("Force-split does not fire when not in speech")
    func forceSplitIgnoredOutsideSpeech() {
        var planner = Qwen3SegmentPlanner(maxSegmentDuration: 1.0)
        #expect(planner.checkForceSplit(at: 100.0) == nil)
    }

    @Test("Repeated force-splits during a sustained monologue keep chunking")
    func multipleForceSplitsCoverWholeMonologue() {
        // A 30s monologue with maxSegmentDuration=10 should produce
        // three force-splits before VAD finally emits speechEnded.
        var planner = Qwen3SegmentPlanner(maxSegmentDuration: 10.0)
        _ = planner.handle(.speechStarted(time: 0.0))
        var splits: [Qwen3SegmentBoundary] = []
        if let s = planner.checkForceSplit(at: 10.5) { splits.append(s) }
        if let s = planner.checkForceSplit(at: 21.0) { splits.append(s) }
        if let s = planner.checkForceSplit(at: 31.5) { splits.append(s) }
        if let tail = planner.handle(.speechEnded(segment: segment(0.0, 33.0))) {
            splits.append(tail)
        }
        #expect(splits.count == 4, "Expected 3 force-splits + 1 closing boundary, got \(splits.count)")
        // No boundary exceeds the cap (with a small slop for chunk granularity).
        for b in splits {
            #expect(b.duration <= 11.5,
                    "Boundary \(b.startTime)-\(b.endTime) exceeds force-split cap")
        }
        // Boundaries are contiguous (each starts where the previous ended).
        for i in 1..<splits.count {
            #expect(abs(splits[i].startTime - splits[i - 1].endTime) < 0.001,
                    "Gap between \(splits[i - 1].endTime) and \(splits[i].startTime)")
        }
    }

    // MARK: - Flush

    @Test("Flush emits any in-progress speech as a final boundary")
    func flushEmitsInProgress() {
        var planner = Qwen3SegmentPlanner()
        _ = planner.handle(.speechStarted(time: 2.0))
        guard let tail = planner.flush(at: 7.0) else {
            Issue.record("Expected flush to emit in-progress speech")
            return
        }
        #expect(abs(tail.startTime - 2.0) < 0.001)
        #expect(abs(tail.endTime - 7.0) < 0.001)
    }

    @Test("Flush in silence emits nothing")
    func flushInSilenceIsNoOp() {
        var planner = Qwen3SegmentPlanner()
        #expect(planner.flush(at: 5.0) == nil)
    }

    // MARK: - Boundary → SampleRange

    @Test("Boundary maps to inclusive-exclusive sample indices at 16 kHz")
    func sampleIndices() {
        let b = Qwen3SegmentBoundary(startTime: 0.5, endTime: 1.0)
        let range = b.sampleRange(sampleRate: 16_000, totalSamples: 32_000)
        #expect(range.lowerBound == 8_000)
        #expect(range.upperBound == 16_000)
    }

    @Test("sampleRange clamps to totalSamples to avoid out-of-bounds slices")
    func sampleIndicesClamped() {
        let b = Qwen3SegmentBoundary(startTime: 0.0, endTime: 100.0)
        let range = b.sampleRange(sampleRate: 16_000, totalSamples: 32_000)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 32_000)
    }
}

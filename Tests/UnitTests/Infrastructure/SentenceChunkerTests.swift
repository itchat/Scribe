import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

/// Verifies cue-shaped chunking + duration weighting that the offline
/// recognizers (Qwen3 + FluidAudio fallback) use to convert a one-blob
/// transcript into watchable SRT cues.
@Suite("SentenceChunker")
struct SentenceChunkerTests {

    // MARK: - chunk(_:maxCharsPerChunk:)

    @Test("Short sentences pass through unchanged")
    func shortSentencesUnchanged() {
        let chunks = SentenceChunker.chunk("Hi. Bye.", maxCharsPerChunk: 80)
        #expect(chunks == ["Hi.", "Bye."])
    }

    @Test("Long English sentence subdivides at commas")
    func longEnglishSplitsOnCommas() {
        let s = "I woke up early, packed my lunch, drove through traffic for thirty minutes, " +
                "and then sat down at my desk to start another day at the office."
        let chunks = SentenceChunker.chunk(s, maxCharsPerChunk: 50)
        // Every chunk respects the cap.
        for chunk in chunks {
            #expect(chunk.count <= 60, "chunk too long: \(chunk.count) chars — \(chunk)")
        }
        // No chunk is empty.
        for chunk in chunks {
            #expect(!chunk.isEmpty)
        }
        // Joined chunks contain all original words (no token loss).
        let joined = chunks.joined(separator: " ")
        #expect(joined.contains("woke up early"))
        #expect(joined.contains("desk to start"))
    }

    @Test("Long Chinese sentence subdivides at full-width commas")
    func longChineseSplitsOnFullWidthCommas() {
        let s = "今天天气很好，我们一起去爬山，山顶上能看到整座城市，傍晚还能看到日落，真是难得的好日子。"
        let chunks = SentenceChunker.chunk(s, maxCharsPerChunk: 15)
        for chunk in chunks {
            #expect(chunk.count <= 25, "chunk too long: \(chunk.count) chars — \(chunk)")
        }
        // The output should preserve every character (modulo the punctuation
        // we dropped or whitespace we trimmed).
        let joined = chunks.joined()
        #expect(joined.contains("爬山"))
        #expect(joined.contains("日落"))
    }

    @Test("Sentence with no punctuation hard-splits at word boundary")
    func longTextHardSplitsAtWords() {
        let s = "this is a very long sentence with no commas at all and it just keeps going and going and going"
        let chunks = SentenceChunker.chunk(s, maxCharsPerChunk: 30)
        for chunk in chunks {
            #expect(chunk.count <= 35, "chunk overflowed: \(chunk.count) — \(chunk)")
            #expect(!chunk.hasPrefix(" "), "chunk should be trimmed")
        }
        // Joined still contains the full content.
        let joined = chunks.joined(separator: " ")
        #expect(joined.contains("very long sentence"))
        #expect(joined.contains("going and going"))
    }

    @Test("Empty input returns empty chunk array")
    func emptyInputReturnsEmpty() {
        #expect(SentenceChunker.chunk("", maxCharsPerChunk: 80).isEmpty)
    }

    // MARK: - makeSegments(text:duration:maxCharsPerChunk:)

    @Test("makeSegments distributes duration in proportion to chunk char count")
    func segmentsWeightDurationByCharCount() {
        // 10s audio, two chunks "ab." (3 chars) and "cdefghij." (9 chars)
        // → first gets 3/12 of the time, second 9/12
        let segments = SentenceChunker.makeSegments(
            text: "ab. cdefghij.",
            duration: 12.0,
            maxCharsPerChunk: 80
        )
        #expect(segments.count == 2)
        // First chunk ~25% of duration, second ~75%.
        #expect(abs(segments[0].end - segments[0].start - 3.0) < 0.5)
        #expect(abs(segments[1].end - segments[1].start - 9.0) < 0.5)
        // Segments are contiguous: no gaps, no overlaps.
        #expect(segments[0].start == 0.0)
        #expect(abs(segments[0].end - segments[1].start) < 0.001)
        // Last segment ends exactly at total duration.
        #expect(abs(segments.last!.end - 12.0) < 0.001)
    }

    @Test("makeSegments breaks long cues so no single cue spans the whole audio")
    func segmentsCapMaxCueCount() {
        // 60s audio with one long sentence → must produce ≥2 cues so the
        // viewer doesn't see a wall-of-text the entire time.
        let s = "I woke up early, packed my lunch, drove through traffic, " +
                "sat down at my desk, opened my laptop, and started another day."
        let segments = SentenceChunker.makeSegments(text: s, duration: 60.0, maxCharsPerChunk: 50)
        #expect(segments.count >= 3, "expected long sentence to be chunked into ≥3 cues, got \(segments.count)")
        // No single cue should span more than half the audio.
        for seg in segments {
            #expect(seg.end - seg.start < 30.0, "cue too long: \(seg.end - seg.start)s")
        }
    }

    @Test("makeSegments on empty text returns empty segments")
    func segmentsEmptyText() {
        let segments = SentenceChunker.makeSegments(text: "", duration: 10.0, maxCharsPerChunk: 80)
        #expect(segments.isEmpty)
    }
}

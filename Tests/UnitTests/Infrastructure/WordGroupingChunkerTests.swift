import Testing
import Foundation
import Qwen3ASR
import AudioCommon
@testable import Domain
@testable import Infrastructure

/// Verifies the cue-builder that groups Qwen3-ForcedAligner's word-level
/// timestamps into reading-shaped SRT cues. Compared to `SentenceChunker`'s
/// char-weighted heuristic this preserves real acoustic boundaries
/// (start of cue = start of first word, end of cue = end of last word).
@Suite("WordGroupingChunker")
struct WordGroupingChunkerTests {

    // Helper — build a synthetic `[AlignedWord]` with deterministic
    // 0.5s-per-word spacing for assertions.
    private func makeWords(_ tokens: [String], step: Float = 0.5) -> [AlignedWord] {
        tokens.enumerated().map { i, token in
            AlignedWord(
                text: token,
                startTime: Float(i) * step,
                endTime: Float(i + 1) * step
            )
        }
    }

    @Test("Empty input returns empty segments")
    func emptyInput() {
        let segments = WordGroupingChunker.makeSegments(words: [])
        #expect(segments.isEmpty)
    }

    @Test("Single word becomes a single segment with its own timestamps")
    func singleWord() {
        let words = [AlignedWord(text: "Hi.", startTime: 1.5, endTime: 2.0)]
        let segments = WordGroupingChunker.makeSegments(words: words)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Hi.")
        #expect(abs(segments[0].start - 1.5) < 0.001)
        #expect(abs(segments[0].end - 2.0) < 0.001)
    }

    @Test("Sentence terminators force a cue break (preferred over char limit)")
    func breaksOnSentenceTerminator() {
        // 3 words ending each sentence, 9 words total → 3 cues.
        let words = makeWords(["Hello", "world.", "How", "are", "you?", "I", "am", "fine", "today."])
        let segments = WordGroupingChunker.makeSegments(words: words, maxCharsPerChunk: 200)
        #expect(segments.count == 3)
        #expect(segments[0].text == "Hello world.")
        #expect(segments[1].text == "How are you?")
        #expect(segments[2].text == "I am fine today.")
        // First cue spans first 2 words.
        #expect(abs(segments[0].start - 0.0) < 0.001)
        #expect(abs(segments[0].end - 1.0) < 0.001)
        // Cues are contiguous (next cue starts where last word ended).
        #expect(abs(segments[1].start - 1.0) < 0.001)
    }

    @Test("Long sentence without terminator breaks at char limit")
    func breaksOnCharLimit() {
        // 8 short words, 4 chars each + space = ~5 chars/word → 40 chars total.
        let words = makeWords(["abcd", "efgh", "ijkl", "mnop", "qrst", "uvwx", "yzab", "cdef"])
        let segments = WordGroupingChunker.makeSegments(words: words, maxCharsPerChunk: 20)
        // Should produce 2-3 cues (each capped near 20 chars).
        #expect(segments.count >= 2)
        for seg in segments {
            #expect(seg.text.count <= 30, "cue too long: \(seg.text.count) chars — \(seg.text)")
        }
    }

    @Test("Full-width Chinese terminators trigger cue breaks")
    func chineseTerminatorBreaks() {
        let words = makeWords(["今天", "天气", "很好。", "我们", "去", "爬山！"])
        let segments = WordGroupingChunker.makeSegments(words: words, maxCharsPerChunk: 200)
        #expect(segments.count == 2)
        #expect(segments[0].text.contains("很好。"))
        #expect(segments[1].text.contains("爬山！"))
    }

    @Test("Cue timestamps reflect first and last word's acoustic boundaries")
    func timestampsAreAcoustic() {
        // 5 words at 1.0s/word.
        let words = makeWords(["one", "two", "three.", "four", "five."], step: 1.0)
        let segments = WordGroupingChunker.makeSegments(words: words, maxCharsPerChunk: 200)
        #expect(segments.count == 2)
        // First cue: words 0-2 → starts at 0.0, ends at 3.0
        #expect(abs(segments[0].start - 0.0) < 0.001)
        #expect(abs(segments[0].end - 3.0) < 0.001)
        // Second cue: words 3-4 → starts at 3.0, ends at 5.0
        #expect(abs(segments[1].start - 3.0) < 0.001)
        #expect(abs(segments[1].end - 5.0) < 0.001)
    }

    @Test("Final words without trailing terminator still emit a cue")
    func tailWithoutTerminator() {
        let words = makeWords(["abc.", "def", "ghi"])
        let segments = WordGroupingChunker.makeSegments(words: words, maxCharsPerChunk: 200)
        #expect(segments.count == 2)
        #expect(segments[0].text == "abc.")
        #expect(segments[1].text == "def ghi")
    }
}

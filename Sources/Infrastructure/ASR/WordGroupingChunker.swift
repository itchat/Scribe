import Foundation
import Domain
import AudioCommon

/// Builds SRT cues out of `[AlignedWord]` produced by Qwen3-ForcedAligner.
///
/// SRP: groups adjacent words into reading-sized cues whose start/end
/// times come straight from the aligner's acoustic word boundaries —
/// no even-distribution or char-weighted approximation. Compared to
/// `SentenceChunker`, this is the precise path; `SentenceChunker`
/// remains the fallback for paths without word-level timestamps.
///
/// Break policy:
/// 1. After a word ending in a sentence terminator (`.!?。！？`), emit
///    a cue. This keeps cue boundaries on natural pauses.
/// 2. If accumulated chars exceed `maxCharsPerChunk` and we're between
///    sentences, emit early so a cue never paints a wall of text.
///
/// Cue timestamps:
/// - `start` = first word's `startTime`
/// - `end`   = last word's `endTime`
/// - Floats from `AlignedWord` are widened to `Double` for the domain type.
public enum WordGroupingChunker {

    public static let defaultMaxCharsPerChunk = 80

    public static func makeSegments(
        words: [AlignedWord],
        maxCharsPerChunk: Int = defaultMaxCharsPerChunk
    ) -> [Domain.TranscriptionSegment] {
        guard !words.isEmpty else { return [] }

        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]

        var segments: [Domain.TranscriptionSegment] = []
        var current: [AlignedWord] = []
        var currentLen = 0

        @inline(__always)
        func emit() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                current.removeAll(keepingCapacity: true)
                currentLen = 0
                return
            }
            segments.append(Domain.TranscriptionSegment(
                text: text,
                start: Double(first.startTime),
                end: Double(last.endTime)
            ))
            current.removeAll(keepingCapacity: true)
            currentLen = 0
        }

        for word in words {
            let separatorCost = current.isEmpty ? 0 : 1
            let projectedLen = currentLen + separatorCost + word.text.count

            // Char-cap pre-emption: if adding this word would exceed the cap
            // AND we already have content, flush before adding.
            if projectedLen > maxCharsPerChunk && !current.isEmpty {
                emit()
            }

            current.append(word)
            currentLen += (current.count == 1 ? word.text.count : 1 + word.text.count)

            // Sentence-terminator break: end the cue here regardless of
            // length so cue boundaries fall on natural pauses.
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.last, terminators.contains(last) {
                emit()
            }
        }

        // Flush the trailing cue.
        if !current.isEmpty {
            emit()
        }
        return segments
    }
}

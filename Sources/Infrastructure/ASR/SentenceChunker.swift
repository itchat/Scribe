import Foundation
import Domain

/// Builds reading-shaped SRT cues out of a one-blob transcript.
///
/// SRP: takes raw text + total audio duration and returns
/// `TranscriptionSegment`s that fit two SRT contracts:
/// 1. **Cue width**: every chunk fits within `maxCharsPerChunk` so a single
///    cue never paints a wall of text on the player. Long sentences are
///    subdivided at soft punctuation (`,` / `，` / `;` / `；`) first and
///    fall back to word-boundary splits when no soft punctuation is present.
/// 2. **Cue duration**: each chunk's on-screen time is proportional to its
///    character count over the total transcript length. Compared to
///    even-time-distribution this handles uneven sentence lengths much
///    better — a 5-char cue doesn't sit on screen as long as a 60-char
///    one — though it remains an approximation in the absence of true
///    token-level timestamps.
///
/// Used by both `Qwen3OfflineRecognizer` (returns one big text blob with
/// no timings) and `FluidAudioRecognizer`'s no-token-timings fallback
/// path. Token-level timing paths bypass this helper entirely.
public enum SentenceChunker {

    /// Conservative SRT cue width. ~80 chars renders as roughly two lines
    /// at typical font sizes — what most subtitle conventions recommend.
    public static let defaultMaxCharsPerChunk = 80

    /// Subdivide free-form transcript into reading-sized chunks.
    /// - Parameters:
    ///   - text: raw transcript.
    ///   - maxCharsPerChunk: target maximum chunk size. Soft cap — hard
    ///     splits may overflow by one word if the trailing word would
    ///     otherwise produce a tiny dangling chunk.
    public static func chunk(_ text: String, maxCharsPerChunk: Int = defaultMaxCharsPerChunk) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sentences = SentenceSplitter.split(trimmed).filter { !$0.isEmpty }
        var chunks: [String] = []
        for sentence in sentences {
            if sentence.count <= maxCharsPerChunk {
                chunks.append(sentence)
            } else {
                chunks.append(contentsOf: subdivide(sentence, maxCharsPerChunk: maxCharsPerChunk))
            }
        }
        return chunks
    }

    /// Build segments whose durations sum exactly to `duration`, each
    /// proportional to its character count. Returns `[]` for empty text.
    public static func makeSegments(
        text: String,
        duration: Double,
        maxCharsPerChunk: Int = defaultMaxCharsPerChunk
    ) -> [Domain.TranscriptionSegment] {
        let chunks = chunk(text, maxCharsPerChunk: maxCharsPerChunk)
        guard !chunks.isEmpty, duration > 0 else { return [] }

        // Treat each chunk as having at least one char so degenerate
        // empty/whitespace chunks (already filtered out, but defensive)
        // can't blow up the divisor.
        let totalChars = chunks.reduce(0) { $0 + max(1, $1.count) }
        var segments: [Domain.TranscriptionSegment] = []
        segments.reserveCapacity(chunks.count)

        var cursor: Double = 0
        for (i, chunk) in chunks.enumerated() {
            let isLast = i == chunks.count - 1
            // Pin the final segment's end exactly at `duration` to avoid
            // accumulated floating-point drift across many chunks.
            let end = isLast ? duration : cursor + duration * Double(max(1, chunk.count)) / Double(totalChars)
            segments.append(Domain.TranscriptionSegment(text: chunk, start: cursor, end: end))
            cursor = end
        }
        return segments
    }

    // MARK: - Private

    /// Soft punctuation split — a long sentence becomes multiple cues at
    /// natural mid-sentence pauses. Falls back to word-boundary split if
    /// no soft punctuation is present (or if any post-soft-split chunk is
    /// still too long).
    private static func subdivide(_ sentence: String, maxCharsPerChunk: Int) -> [String] {
        let softTerminators = CharacterSet(charactersIn: ",，;；:：")
        let pieces = sentence
            .components(separatedBy: softTerminators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidates = pieces.count > 1 ? pieces : [sentence]
        var result: [String] = []
        for piece in candidates {
            if piece.count <= maxCharsPerChunk {
                result.append(piece)
            } else {
                result.append(contentsOf: hardSplit(piece, maxCharsPerChunk: maxCharsPerChunk))
            }
        }
        return result
    }

    /// Last-resort split: accumulate words up to the cap. Works for both
    /// space-separated languages and Chinese (which has no inter-word
    /// spacing — there a single "word" can be the whole string, so we
    /// fall through to a character-count slice).
    private static func hardSplit(_ text: String, maxCharsPerChunk: Int) -> [String] {
        // Word-boundary attempt first.
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.count > 1 {
            var chunks: [String] = []
            var current: [String] = []
            var currentLen = 0
            for word in words {
                let separatorCost = current.isEmpty ? 0 : 1
                if currentLen + separatorCost + word.count > maxCharsPerChunk && !current.isEmpty {
                    chunks.append(current.joined(separator: " "))
                    current = [word]
                    currentLen = word.count
                } else {
                    current.append(word)
                    currentLen += separatorCost + word.count
                }
            }
            if !current.isEmpty {
                chunks.append(current.joined(separator: " "))
            }
            return chunks
        }

        // Fallback for whitespace-free strings (typical Chinese): slice
        // by character count, respecting Swift's grapheme-cluster index.
        var chunks: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: maxCharsPerChunk, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[idx..<next]).trimmingCharacters(in: .whitespacesAndNewlines))
            idx = next
        }
        return chunks.filter { !$0.isEmpty }
    }
}

import Foundation

/// Splits a free-form transcript string into sentence-shaped segments.
///
/// Used as the timing fallback for any ASR engine that returns one big
/// blob of text instead of token-level timings: we slice on terminal
/// punctuation, then the caller distributes the audio duration evenly
/// across the resulting segments to produce SRT cues.
///
/// SRP: this type does one thing — sentence segmentation. It does not
/// know about timestamps, audio, or transcription.
///
/// Recognises both ASCII (`.` `!` `?`) and full-width CJK (`。` `！` `？`)
/// terminators so it works for the English-only Parakeet path *and* the
/// Chinese / mixed-language Qwen3 path.
public enum SentenceSplitter {

    /// Returns one trimmed sentence per terminator. Whitespace-only
    /// segments are dropped. Input with no terminator returns a single-
    /// element array containing the original (trimmed) input. Empty input
    /// returns `[""]` so callers can rely on a non-empty return value.
    public static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [""] }

        // Match runs of non-terminator characters followed by ≥1 terminator.
        // Terminators: . ! ? plus the full-width Chinese 。 ！ ？
        let pattern = #"[^.!?。！？]+[.!?。！？]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        let sentences = matches.compactMap { match -> String? in
            guard let r = Range(match.range, in: text) else { return nil }
            let segment = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return segment.isEmpty ? nil : segment
        }

        if sentences.isEmpty {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return sentences
    }
}

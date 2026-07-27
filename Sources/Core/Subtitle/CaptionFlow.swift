import Foundation
import Domain

/// Decides how finalized caption lines are joined for on-screen reading.
///
/// SOLID:
/// - **SRP**: only answers "what goes between these two utterances". It owns
///   no view state and performs no layout.
///
/// Commit granularity and display granularity are deliberately different
/// concerns. Engines commit one `LiveCaptionEntry` per utterance because that
/// is what SRT cues need — but an utterance is not a line. Qwen3's
/// segmentation is VAD-driven, so an ordinary mid-sentence pause ends a
/// segment, and the model then punctuates that fragment as though it were a
/// whole sentence. Rendering one entry per line turned continuous speech into
/// a column of stubs:
///
///     回答的是。
///     是谁?
///     文明回答的是。
///
/// Those are one thought. They read correctly only when flowed together, so
/// the transcript view joins entries into running text and lets the text
/// container wrap. SRT export is unaffected — it still gets one cue per entry.
public enum CaptionFlow {

    /// Characters after which a space would be wrong in CJK text.
    ///
    /// Chinese and Japanese are written without inter-word spaces, and their
    /// full-width punctuation already carries the trailing gap visually.
    private static let cjkTrailing: Set<Character> = [
        "。", "？", "！", "，", "、", "；", "：", "”", "’", "）", "》", "」", "』", "…", "—",
    ]

    private static let cjkLeading: Set<Character> = [
        "“", "‘", "（", "《", "「", "『",
    ]

    /// Whether a scalar belongs to a script written without word spacing.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK ext A
             0x4E00...0x9FFF,   // CJK unified
             0xF900...0xFAFF,   // CJK compatibility
             0xFF00...0xFFEF,   // half/full-width forms
             0x20000...0x2FA1F: // CJK ext B+
            return true
        default:
            return false
        }
    }

    /// The separator to place between two consecutive utterances.
    ///
    /// Empty for CJK boundaries, a single space where Latin text would
    /// otherwise run together.
    public static func separator(after previous: String, before next: String) -> String {
        guard let last = previous.last(where: { !$0.isWhitespace }),
              let first = next.first(where: { !$0.isWhitespace })
        else { return "" }

        if cjkTrailing.contains(last) || cjkLeading.contains(first) { return "" }
        if let lastScalar = last.unicodeScalars.last, isCJK(lastScalar) { return "" }
        if let firstScalar = first.unicodeScalars.first, isCJK(firstScalar) { return "" }
        return " "
    }

    /// Join finalized entries into a single readable run of text.
    ///
    /// Used for the clipboard and for the full rebuild path in the transcript
    /// view; the incremental path applies `separator(after:before:)` per
    /// appended entry to get the same result without rebuilding.
    public static func joined(_ entries: [LiveCaptionEntry]) -> String {
        entries.reduce(into: "") { result, entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if result.isEmpty {
                result = text
            } else {
                result += separator(after: result, before: text) + text
            }
        }
    }
}

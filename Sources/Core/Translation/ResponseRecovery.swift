import Foundation
import Domain

/// Recovers translated text segments from a combined translation response.
///
/// Translation APIs receive batched text joined by separators. The response must be split
/// back into individual translations. When the primary separator is mangled by the API,
/// this type tries alternate separators, then line-based splitting, then gives up gracefully.
///
/// SRP: Only responsible for splitting a combined response string back into parts.
/// Extracted from Python's `BaseTranslator.recover_split_result()` + `pad_or_truncate_translations()`.
public enum ResponseRecovery {

    /// Attempt to split `combined` into `expectedCount` parts using `separator`,
    /// falling back to alternate strategies if the count doesn't match.
    public static func recover(
        combined: String,
        expectedCount: Int,
        separator: String
    ) -> [String] {
        // 1. Try primary separator
        let primarySplit = combined.components(separatedBy: separator)
        if primarySplit.count == expectedCount {
            return primarySplit
        }

        // 2. Try alternate separators
        for altSep in Constants.alternateSeparators {
            if altSep == separator { continue }
            let altSplit = combined.components(separatedBy: altSep)
            if altSplit.count == expectedCount {
                return altSplit
            }
        }

        // 3. Try line-based splitting
        let lines = combined.components(separatedBy: "\n")
        if lines.count >= expectedCount {
            let linesPerEntry = lines.count / expectedCount
            var result: [String] = []
            for i in 0..<expectedCount {
                let startIdx = i * linesPerEntry
                let endIdx = (i < expectedCount - 1) ? startIdx + linesPerEntry : lines.count
                let entryText = lines[startIdx..<endIdx].joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                result.append(entryText)
            }
            return result
        }

        // 4. Can't recover — return raw split
        return primarySplit
    }

    /// Pad or truncate translations to match the number of original entries.
    /// Missing translations are filled with the original entry text.
    public static func padOrTruncate(
        translations: [String],
        entries: [SubtitleEntry]
    ) -> [String] {
        let expected = entries.count
        var result = translations

        if result.count < expected {
            for i in result.count..<expected {
                result.append(entries[i].text)
            }
        } else if result.count > expected {
            result = Array(result.prefix(expected))
        }

        return result
    }
}

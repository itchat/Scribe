import Foundation
import Domain

/// Splits subtitle entries into translation batches respecting character and entry limits.
///
/// SRP: Only responsible for partitioning entries into batches.
/// Extracted from Python's `BaseTranslator.split_into_batches()`.
public enum BatchSplitter {

    /// Split entries into batches.
    /// - Parameters:
    ///   - entries: All subtitle entries to split.
    ///   - maxChars: Maximum total characters per batch (default from Constants).
    ///   - maxEntries: Maximum number of entries per batch (default from Constants).
    /// - Returns: Array of batches, each batch is an array of entries.
    public static func split(
        _ entries: [SubtitleEntry],
        maxChars: Int = Constants.defaultMaxCharsPerBatch,
        maxEntries: Int = Constants.defaultMaxEntriesPerBatch
    ) -> [[SubtitleEntry]] {
        guard !entries.isEmpty else { return [] }

        var batches: [[SubtitleEntry]] = []
        var currentBatch: [SubtitleEntry] = []
        var currentChars = 0

        for entry in entries {
            let entryLength = entry.text.count

            let shouldStartNewBatch =
                !currentBatch.isEmpty &&
                (currentBatch.count >= maxEntries || currentChars + entryLength > maxChars)

            if shouldStartNewBatch {
                batches.append(currentBatch)
                currentBatch = []
                currentChars = 0
            }

            currentBatch.append(entry)
            currentChars += entryLength
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches
    }
}

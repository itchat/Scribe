import Foundation
import Domain

/// Converts a list of finalized `LiveCaptionEntry`s into export formats.
///
/// SRP: only formatting. File I/O lives in the App layer (NSSavePanel).
/// Reuses the existing `SRTWriter` so SRT output stays consistent with the
/// batch transcription path.
public enum LiveCaptionExporter {

    /// Default cue length when there is only a single entry: we want a
    /// non-zero duration so SRT players show the line at all.
    public static let singleEntryFallbackDuration: TimeInterval = 3.0

    /// Build SRT text from the entries. Each cue spans from the previous
    /// entry's `emittedAt` (or `sessionStart` for the first) up to its own
    /// `emittedAt`. That window roughly corresponds to the speech window
    /// that produced the caption.
    public static func srt(entries: [LiveCaptionEntry], sessionStart: Date) -> String {
        guard !entries.isEmpty else { return "" }

        var subtitleEntries: [SubtitleEntry] = []
        var previousEnd: TimeInterval = 0
        for (index, entry) in entries.enumerated() {
            let endOffset = max(previousEnd, entry.emittedAt.timeIntervalSince(sessionStart))
            // For the very first entry — or any entry that arrives instantly
            // after the previous — give it a small minimum on-screen window
            // so SRT players don't render a zero-length cue.
            let startOffset: TimeInterval
            if index == 0 && previousEnd == 0 {
                startOffset = max(0, endOffset - singleEntryFallbackDuration)
            } else {
                startOffset = previousEnd
            }
            let safeEnd = max(startOffset + 0.5, endOffset)
            subtitleEntries.append(SubtitleEntry(
                id: index + 1,
                timestamp: SubtitleTimestamp(start: startOffset, end: safeEnd),
                text: entry.text
            ))
            previousEnd = safeEnd
        }

        return SRTWriter.write(subtitleEntries)
    }

    /// Plain text — one caption per line.
    public static func plainText(entries: [LiveCaptionEntry]) -> String {
        entries.map(\.text).joined(separator: "\n")
    }

    /// All caption text concatenated for clipboard copy. Same shape as plain
    /// text export; kept as a separate method for callsite clarity.
    public static func clipboardString(entries: [LiveCaptionEntry], current: String) -> String {
        var lines = entries.map(\.text)
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCurrent.isEmpty { lines.append(trimmedCurrent) }
        return lines.joined(separator: "\n")
    }
}

import Foundation
import Domain
import Protocols

/// Converts a `TranscriptionResult` into subtitle entries.
///
/// Conforms to `SubtitleFormatting` protocol (DIP: injected into pipeline).
public struct SubtitleFormatter: SubtitleFormatting, Sendable {

    public init() {}

    public func format(result: TranscriptionResult) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        var nextID = 1

        for segment in result.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            entries.append(SubtitleEntry(
                id: nextID,
                timestamp: SubtitleTimestamp(start: segment.start, end: segment.end),
                text: trimmed
            ))
            nextID += 1
        }

        return entries
    }
}

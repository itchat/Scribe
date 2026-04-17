import Foundation
import Domain

/// Parses SRT-format text into strongly-typed subtitle entries.
///
/// SRP: Only responsible for SRT text → [SubtitleEntry].
/// Extracted from Python's `BaseTranslator.parse_srt_entries()` which was a 394-line god class.
public enum SRTParser {

    private enum ParsingState {
        case id
        case timestamp
        case text
    }

    /// Parse an SRT-format string into subtitle entries.
    public static func parse(_ srtContent: String) throws -> [SubtitleEntry] {
        let lines = srtContent.components(separatedBy: "\n")
        var entries: [SubtitleEntry] = []

        var currentID: Int?
        var currentTimestamp: SubtitleTimestamp?
        var currentTextLines: [String] = []
        var state: ParsingState = .id

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line = entry boundary
            if trimmed.isEmpty {
                if let id = currentID, let timestamp = currentTimestamp, !currentTextLines.isEmpty {
                    entries.append(SubtitleEntry(
                        id: id,
                        timestamp: timestamp,
                        text: currentTextLines.joined(separator: "\n")
                    ))
                }
                currentID = nil
                currentTimestamp = nil
                currentTextLines = []
                state = .id
                continue
            }

            switch state {
            case .id:
                if let id = Int(trimmed) {
                    currentID = id
                    state = .timestamp
                }

            case .timestamp:
                if trimmed.contains("-->") {
                    currentTimestamp = try SubtitleTimestamp(srtString: trimmed)
                    state = .text
                }

            case .text:
                currentTextLines.append(trimmed)
            }
        }

        // Handle last entry (no trailing newline)
        if let id = currentID, let timestamp = currentTimestamp, !currentTextLines.isEmpty {
            entries.append(SubtitleEntry(
                id: id,
                timestamp: timestamp,
                text: currentTextLines.joined(separator: "\n")
            ))
        }

        return entries
    }
}

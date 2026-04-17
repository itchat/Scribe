import Foundation

/// Errors thrown when parsing SRT timestamp strings.
public enum SubtitleTimestampError: Error, Equatable {
    case invalidFormat(String)
    case missingSeparator
    case invalidTimeComponent(String)
}

/// A time range representing a subtitle's display window.
///
/// Immutable value type. Parses from and formats to SRT timestamp strings
/// like `"00:01:23,456 --> 00:01:25,789"`.
public struct SubtitleTimestamp: Codable, Equatable, Sendable {
    /// Start time in seconds.
    public let start: TimeInterval
    /// End time in seconds.
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    /// Parse from an SRT-format timestamp string.
    ///
    /// Expected format: `"HH:MM:SS,mmm --> HH:MM:SS,mmm"`
    public init(srtString: String) throws {
        let trimmed = srtString.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            throw SubtitleTimestampError.invalidFormat(srtString)
        }

        guard let arrowRange = trimmed.range(of: "-->") else {
            throw SubtitleTimestampError.missingSeparator
        }

        let startStr = trimmed[trimmed.startIndex..<arrowRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let endStr = trimmed[arrowRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)

        self.start = try Self.parseTimeComponent(startStr)
        self.end = try Self.parseTimeComponent(endStr)
    }

    /// Duration in seconds.
    public var duration: TimeInterval {
        end - start
    }

    /// Format as SRT timestamp string: `"HH:MM:SS,mmm --> HH:MM:SS,mmm"`.
    public var srtFormatted: String {
        "\(Self.formatTimeComponent(start)) --> \(Self.formatTimeComponent(end))"
    }

    // MARK: - Private

    private static func parseTimeComponent(_ string: String) throws -> TimeInterval {
        // Expected: "HH:MM:SS,mmm"
        let parts = string.split(separator: ",")
        guard parts.count == 2 else {
            throw SubtitleTimestampError.invalidTimeComponent(string)
        }

        let timeParts = parts[0].split(separator: ":")
        guard timeParts.count == 3,
              let hours = Int(timeParts[0]),
              let minutes = Int(timeParts[1]),
              let seconds = Int(timeParts[2]),
              let millis = Int(parts[1])
        else {
            throw SubtitleTimestampError.invalidTimeComponent(string)
        }

        return TimeInterval(hours * 3600 + minutes * 60 + seconds) + TimeInterval(millis) / 1000.0
    }

    private static func formatTimeComponent(_ seconds: TimeInterval) -> String {
        let totalMillis = Int(round(seconds * 1000))
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis % 3_600_000) / 60_000
        let secs = (totalMillis % 60_000) / 1_000
        let millis = totalMillis % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

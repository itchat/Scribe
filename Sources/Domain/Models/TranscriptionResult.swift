import Foundation

/// A segment of transcribed speech with timing information.
public struct TranscriptionSegment: Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The result of a speech-to-text transcription.
public struct TranscriptionResult: Sendable {
    /// Full transcribed text.
    public let text: String
    /// Sentence-level segments with timing.
    public let segments: [TranscriptionSegment]

    public init(text: String, segments: [TranscriptionSegment]) {
        self.text = text
        self.segments = segments
    }
}

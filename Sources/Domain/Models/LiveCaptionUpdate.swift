import Foundation

/// A single update emitted by a streaming transcriber.
///
/// `text` is the entire current partial transcript so far (engines like Nemotron
/// emit cumulative partials, not deltas). `isFinal` is true after the user
/// stops the session and the engine flushes its final transcript.
public struct LiveCaptionUpdate: Sendable, Equatable {
    public let text: String
    public let timestamp: Date
    public let isFinal: Bool

    public init(text: String, timestamp: Date = Date(), isFinal: Bool = false) {
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}

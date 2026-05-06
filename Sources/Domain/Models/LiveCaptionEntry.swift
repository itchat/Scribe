import Foundation

/// A finalized line in a Live Captions session, with the wall-clock time it
/// was emitted. Pairs of consecutive entries define an SRT cue's timing.
public struct LiveCaptionEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let emittedAt: Date

    public init(id: UUID = UUID(), text: String, emittedAt: Date) {
        self.id = id
        self.text = text
        self.emittedAt = emittedAt
    }
}

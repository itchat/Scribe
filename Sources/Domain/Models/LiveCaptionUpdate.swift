import Foundation

/// A single update emitted by a streaming transcriber.
///
/// `text` is the **current utterance only**, not the whole session.
///
/// - `isFinal == false`: an in-progress utterance. Replaces whatever the
///   previous non-final update carried.
/// - `isFinal == true`: the utterance is settled and will not change.
///   Consumers append it to their transcript and clear the in-progress line.
///
/// Engines emit a final update at each of their own endpoints (sherpa's
/// `isEndpoint()`, Qwen3's segment commit, Nemotron's chunk boundary) and one
/// last time from `finish()`.
///
/// This used to be cumulative — every update carried the entire session
/// transcript and `isFinal` was set only once, at `finish()`. That single
/// decision caused three separate problems: the sherpa engines rebuilt and
/// re-compared the whole transcript on *every* audio buffer (quadratic in
/// session length), the text view replaced its entire `NSTextStorage` several
/// times a second (destroying any active selection, which is what the
/// select-to-translate feature depends on), and SRT export produced a single
/// cue spanning the whole session because `history` only ever received one
/// entry.
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

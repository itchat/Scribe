import Foundation
import Protocols

/// Maps one pipeline stage's own 0–100 progress onto that stage's slice of
/// the overall bar.
///
/// SOLID:
/// - **SRP**: only rescales percentages; status messages pass through.
/// - **DIP**: stages report against their own scale through
///   `ProgressReporting` and never need to know where they sit in the
///   pipeline, so a stage can be reordered or resized here alone.
///
/// Without it, every stage had to hard-code the global range it lived in.
/// The video composer didn't, and reported raw 0–99 while the bar already
/// stood at 80 — so the bar dropped back to single digits and climbed again
/// during every burn.
public final class StageProgressReporter: Protocols.ProgressReporting {

    private let base: (any Protocols.ProgressReporting)?
    private let range: ClosedRange<Int>

    public init(base: (any Protocols.ProgressReporting)?, range: ClosedRange<Int>) {
        self.base = base
        self.range = range
    }

    public func reportProgress(_ percent: Int) {
        let clamped = min(100, max(0, percent))
        let span = range.upperBound - range.lowerBound
        base?.reportProgress(range.lowerBound + span * clamped / 100)
    }

    public func reportStatus(_ message: String) {
        base?.reportStatus(message)
    }
}

/// Turns a stream of fine-grained fractions into whole-percent steps,
/// yielding a value only when the percent actually changes.
///
/// SRP: only de-duplicates. Used by loops that can compute progress far more
/// often than anyone can see it change — the Qwen3 transcription loop runs
/// once per 32 ms of audio, about 225 000 times for a two-hour file.
public struct ProgressThrottle: Sendable {

    private var lastPercent: Int?

    public init() {}

    /// - Returns: the new percent (0–100), or `nil` if it is unchanged.
    public mutating func percent(for fraction: Double) -> Int? {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        guard percent != lastPercent else { return nil }
        lastPercent = percent
        return percent
    }
}

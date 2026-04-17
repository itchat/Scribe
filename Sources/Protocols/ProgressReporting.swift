import Foundation

/// Reports processing progress and status messages.
///
/// ISP fix: Replaces the Python version's bare `Callable[[int], None]` progress callback.
/// Separates progress percentage from status messages so callers can use either or both.
public protocol ProgressReporting: AnyObject, Sendable {
    /// Report a progress percentage (0–100).
    func reportProgress(_ percent: Int)

    /// Report a human-readable status message.
    func reportStatus(_ message: String)
}

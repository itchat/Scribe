import Foundation
import Domain

/// Burns subtitles into a video file.
public protocol VideoComposing: Sendable {
    /// Compose a video with burned-in subtitles.
    /// - Parameter progress: Optional reporter for composition progress (0–100).
    /// - Throws: `ScribeError.ffmpegFailed` or `.compositionTimeout` on failure.
    func compose(
        video: URL,
        subtitles: URL,
        output: URL,
        progress: (any ProgressReporting)?
    ) async throws
}

import Foundation
import Domain

/// Burns subtitles into a video file.
public protocol VideoComposing: Sendable {
    /// Compose a video with burned-in subtitles.
    /// - Parameter style: How the subtitles look (font size, colour,
    ///   position, etc.). Presets are resolved against the input video's
    ///   pixel height inside the implementation; `.custom` passes through.
    /// - Parameter progress: Optional reporter for composition progress (0–100).
    /// - Throws: `ScribeError.ffmpegFailed` or `.compositionTimeout` on failure.
    func compose(
        video: URL,
        subtitles: URL,
        output: URL,
        style: SubtitleStyle,
        progress: (any ProgressReporting)?
    ) async throws
}

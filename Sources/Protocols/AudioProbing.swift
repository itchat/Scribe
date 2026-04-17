import Foundation

/// Inspects audio/video file metadata without modifying files.
///
/// ISP: Separated from `AudioExtracting` because callers that only need
/// to check duration or stream presence shouldn't depend on extraction logic.
public protocol AudioProbing: Sendable {
    /// Whether the video file contains at least one audio stream.
    func hasAudioStream(in videoURL: URL) async throws -> Bool

    /// Duration of an audio file in seconds, or nil if undetermined.
    func duration(of audioURL: URL) async throws -> TimeInterval
}

import Foundation
import Domain

/// Extracts audio from a video file.
///
/// ISP: Split from the Python `AudioExtractor` which also had `has_audio_stream`,
/// `get_audio_duration`, and `create_silent_audio`. Those belong to `AudioProbing`
/// and `SilentAudioCreating` respectively.
public protocol AudioExtracting: Sendable {
    /// Extract audio from a video file to a WAV output.
    /// - Throws: `ScribeError.audioExtractionFailed` on failure.
    func extract(from videoURL: URL, to outputURL: URL) async throws
}

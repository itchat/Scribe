import Foundation
import Domain

/// Transcribes audio to text with timing information.
///
/// LSP fix: Returns strongly-typed `TranscriptionResult` instead of `Any`
/// (the Python version returned `Any` from `SpeechRecognizerInterface.transcribe()`).
public protocol SpeechRecognizing: Sendable {
    /// Transcribe audio at the given URL.
    /// - Parameter progress: Optional reporter for progress updates during
    ///   transcription. Percentages are this stage's own, 0–100; the
    ///   pipeline maps them onto its slice of the overall bar.
    /// - Returns: Strongly-typed transcription result with segments.
    /// - Throws: `ScribeError.transcriptionFailed` on failure.
    func transcribe(audioAt url: URL, progress: (any ProgressReporting)?) async throws -> TranscriptionResult
}

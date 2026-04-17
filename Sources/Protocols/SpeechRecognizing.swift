import Foundation
import Domain

/// Transcribes audio to text with timing information.
///
/// LSP fix: Returns strongly-typed `TranscriptionResult` instead of `Any`
/// (the Python version returned `Any` from `SpeechRecognizerInterface.transcribe()`).
public protocol SpeechRecognizing: Sendable {
    /// Transcribe audio at the given URL.
    /// - Parameter progress: Optional reporter for progress updates during transcription.
    /// - Returns: Strongly-typed transcription result with segments.
    /// - Throws: `ScribeError.transcriptionFailed` on failure.
    func transcribe(audioAt url: URL, progress: (any ProgressReporting)?) async throws -> TranscriptionResult
}

import Foundation
import Domain

/// Converts a transcription result into subtitle entries.
///
/// DIP fix: Injected into `VideoPipeline` instead of the Python version's
/// inline `from core.speech_recognizer import SubtitleFormatter`.
public protocol SubtitleFormatting: Sendable {
    /// Convert transcription segments into subtitle entries.
    func format(result: TranscriptionResult) -> [SubtitleEntry]
}

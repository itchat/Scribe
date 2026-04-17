import Foundation
import Domain

/// Translates subtitle entries from one language to another.
///
/// LSP fix: Uses strongly-typed `[SubtitleEntry]` instead of `List[Dict]`
/// (the Python version passed raw dictionaries).
public protocol SubtitleTranslating: Sendable {
    /// Translate a batch of subtitle entries.
    /// - Returns: Entries with `translatedText` populated.
    /// - Throws: `ScribeError.translationFailed` on failure.
    func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry]

    /// Human-readable name of this translation engine.
    var name: String { get }

    /// Whether this translator is currently available (e.g., API key configured).
    var isAvailable: Bool { get }
}

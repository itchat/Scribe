import Foundation

/// Single 3-way switch that replaces the old `skipTranslation: Bool` +
/// `TranslationEngine` picker pair. Off = no translation; OpenAI/Google
/// = translate via the named engine.
///
/// SOLID:
/// - **OCP**: Adding a new engine = new case + a new `SubtitleTranslating`
///   conformer; the pipeline composition root branches here.
/// - **DIP**: The pipeline depends on `SubtitleTranslating`; this enum
///   only steers which conformer is instantiated.
public enum TranslationMode: String, Codable, Sendable, CaseIterable {
    case off    = "Off"
    case openAI = "OpenAI"
    case google = "Google"

    public var displayName: String {
        switch self {
        case .off:    return "Off"
        case .openAI: return "OpenAI"
        case .google: return "Google"
        }
    }

    /// Map to the legacy `TranslationEngine` enum used by individual
    /// translator implementations. `.off` returns nil — callers should
    /// short-circuit before constructing a translator.
    public func toEngine() -> TranslationEngine? {
        switch self {
        case .off:    return nil
        case .openAI: return .openAI
        case .google: return .google
        }
    }
}

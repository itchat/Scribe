import Foundation
import Domain
import Core

/// Single-string instant translation used by the Live Captions selection
/// popup. Apple's `Translation.TranslationSession` is the preferred
/// engine but it can only be created from a SwiftUI view via
/// `.translationTask`; this helper covers the **Google fallback** path
/// when Apple Translation is unavailable, the user hasn't installed the
/// language pack yet, or the call throws.
///
/// SOLID:
/// - **SRP**: only does "string → string instant translate via Google".
///   Apple's translate call is wired in the View layer because the
///   Apple framework is SwiftUI-bound.
/// - **DIP**: wraps the existing `GoogleTranslator` so we reuse the
///   burn-pipeline's translation chain instead of bolting on a second
///   Google client.
public actor InstantTranslator {

    public init() {}

    /// Detected language direction used to pick a target locale.
    public enum Direction: String, Sendable {
        case zhToEn  // input is predominantly Chinese → translate to English
        case enToZh  // input is predominantly non-Chinese → translate to Chinese

        /// `(source, target)` codes consumed by `GoogleTranslator.init`.
        public var googleLangs: (source: String, target: String) {
            switch self {
            case .zhToEn: return ("zh-CN", "en")
            case .enToZh: return ("en", "zh-CN")
            }
        }

        /// `(source, target)` BCP-47 identifiers used by Apple's
        /// `TranslationSession.Configuration` when the View layer
        /// builds its session.
        public var appleLangs: (source: String, target: String) {
            switch self {
            case .zhToEn: return ("zh-Hans", "en")
            case .enToZh: return ("en", "zh-Hans")
            }
        }
    }

    /// Crude CJK ratio heuristic. Same threshold the offline recognizers
    /// use for picking the aligner's language hint — share a single
    /// rule so behavior across "live" and "burn" pipelines stays
    /// consistent.
    public static func detectDirection(_ text: String) -> Direction {
        var cjkCount = 0
        var totalNonSpace = 0
        for scalar in text.unicodeScalars {
            if !scalar.properties.isWhitespace {
                totalNonSpace += 1
            }
            if (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        guard totalNonSpace > 0 else { return .enToZh }
        return Double(cjkCount) / Double(totalNonSpace) > 0.3 ? .zhToEn : .enToZh
    }

    /// Translate via Google. The view's `.translationTask` modifier tries
    /// Apple first; this is the catch path when Apple throws (no model,
    /// unsupported pair, etc.). Wraps the input as a single-entry array
    /// so the existing batched chain runs without a special path.
    public func translate(_ text: String, direction: Direction) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let langs = direction.googleLangs
        let translator = GoogleTranslator(sourceLang: langs.source, targetLang: langs.target)
        let entry = SubtitleEntry(
            id: 1,
            timestamp: SubtitleTimestamp(start: 0, end: 1),
            text: trimmed
        )
        let translated = try await translator.translate(entries: [entry])
        return translated.first?.translatedText ?? ""
    }
}

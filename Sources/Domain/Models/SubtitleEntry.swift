import Foundation

/// A single subtitle entry with timing, text, and optional translation.
public struct SubtitleEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let timestamp: SubtitleTimestamp
    public let text: String
    public var translatedText: String?

    public init(id: Int, timestamp: SubtitleTimestamp, text: String, translatedText: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.translatedText = translatedText
    }

    /// Returns bilingual text (original + newline + translated) if translation exists,
    /// otherwise returns the original text.
    ///
    /// A translation that adds nothing is dropped: the target language is
    /// fixed, so speech already in that language comes back unchanged, and
    /// `ResponseRecovery.padOrTruncate` fills unrecovered slots with the
    /// original. Writing both lines then burns the same sentence twice.
    public var bilingualText: String {
        guard let translatedText,
              Self.comparable(translatedText) != Self.comparable(text),
              !Self.comparable(translatedText).isEmpty else {
            return text
        }
        return "\(text)\n\(translatedText)"
    }

    /// Text with whitespace and punctuation removed, so a translation that
    /// differs from the original only by `？` vs `?` still counts as a copy.
    private static func comparable(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        })
    }
}

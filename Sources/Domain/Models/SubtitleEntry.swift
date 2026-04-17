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
    public var bilingualText: String {
        if let translatedText {
            return "\(text)\n\(translatedText)"
        }
        return text
    }
}

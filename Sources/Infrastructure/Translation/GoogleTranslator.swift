import Foundation
import os
import Domain
import Protocols
import Core

/// Translates subtitles using the Google Translate free API.
///
/// Uses the same endpoint as `deep-translator` Python library.
/// No API key required.
public final class GoogleTranslator: SubtitleTranslating, @unchecked Sendable {

    private let sourceLang: String
    private let targetLang: String
    private let session: URLSession
    private let logger = Logger(subsystem: "com.scribe", category: "translation.google")

    public var name: String { "Google Translate" }
    public var isAvailable: Bool { true }

    public init(sourceLang: String = "auto", targetLang: String = "zh-CN") {
        self.sourceLang = sourceLang
        self.targetLang = targetLang

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - SubtitleTranslating

    public func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        guard !entries.isEmpty else { return [] }

        let batches = BatchSplitter.split(entries)
        var allTranslated: [SubtitleEntry] = []

        for batch in batches {
            let translated = try await translateBatch(batch)
            allTranslated.append(contentsOf: translated)
        }

        return allTranslated
    }

    // MARK: - Private

    private func translateBatch(_ entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        let texts = entries.map(\.text)
        let combined = texts.joined(separator: Constants.batchSeparatorWithNewlines)

        let translatedCombined = try await callGoogleTranslate(text: combined)

        let recovered = ResponseRecovery.recover(
            combined: translatedCombined,
            expectedCount: entries.count,
            separator: Constants.batchSeparatorWithNewlines
        )
        let translatedTexts = ResponseRecovery.padOrTruncate(translations: recovered, entries: entries)

        return zip(entries, translatedTexts).map { entry, translation in
            var result = entry
            result.translatedText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }
    }

    private func callGoogleTranslate(text: String) async throws -> String {
        // Use the free Google Translate web API
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceLang),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]

        guard let url = components.url else {
            throw ScribeError.translationFailed(
                engine: "Google",
                underlying: NSError(domain: "URL", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to construct Google Translate URL"
                ])
            )
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ScribeError.translationFailed(
                engine: "Google",
                underlying: NSError(domain: "Google", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
            )
        }

        // Parse the nested JSON array response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = json.first as? [Any] else {
            throw ScribeError.translationParseFailed(
                rawResponse: String(data: data, encoding: .utf8) ?? ""
            )
        }

        // Extract translated text from each sentence pair
        let translatedParts = sentences.compactMap { item -> String? in
            guard let pair = item as? [Any], let text = pair.first as? String else { return nil }
            return text
        }

        let result = translatedParts.joined()
        guard !result.isEmpty else {
            throw ScribeError.translationFailed(
                engine: "Google",
                underlying: NSError(domain: "Google", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "Empty response from Google Translate"
                ])
            )
        }

        return result
    }
}

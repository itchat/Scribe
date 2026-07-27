import Foundation
import os
import Domain
import Protocols
import Core

/// Translates subtitles using the OpenAI chat completion API.
public final class OpenAITranslator: SubtitleTranslating, @unchecked Sendable {

    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let systemPrompt: String
    private let session: URLSession
    private let logger = Logger(subsystem: "com.scribe", category: "translation.openai")

    public var name: String { "OpenAI Translate" }
    public var isAvailable: Bool { !apiKey.isEmpty }

    public init(
        apiKey: String,
        baseURL: String = Constants.defaultOpenAIBaseURL,
        model: String = Constants.defaultOpenAIModel,
        systemPrompt: String = Constants.defaultTranslationPrompt
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Constants.apiTimeoutSeconds
        self.session = URLSession(configuration: config)
    }

    // MARK: - SubtitleTranslating

    public func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        guard !entries.isEmpty else { return [] }

        // Fail fast if not configured — lets FallbackTranslator switch to secondary
        guard isAvailable else {
            throw ScribeError.translationFailed(
                engine: name,
                underlying: NSError(domain: "OpenAI", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "API key not configured"
                ])
            )
        }

        let batches = BatchSplitter.split(entries)
        var allTranslated: [SubtitleEntry] = []

        // Let errors propagate so FallbackTranslator can switch engines
        for (i, batch) in batches.enumerated() {
            logger.info("Translating batch \(i + 1)/\(batches.count) with \(batch.count) entries")
            let translated = try await translateBatch(batch)
            allTranslated.append(contentsOf: translated)
        }

        return allTranslated
    }

    // MARK: - Private

    private func translateBatch(_ entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        let texts = entries.map(\.text)
        let body = OpenAIRequestBuilder.buildRequestBody(
            texts: texts,
            model: model,
            systemPrompt: systemPrompt
        )

        // Serialize to Data (Sendable) before passing into the retry closure
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // Return extracted String content (Sendable) from retry block, not raw JSON
        let content: String = try await RetryExecutor.execute(
            maxAttempts: 4,
            baseDelay: 1.0,
            maxDelay: 60.0
        ) { [self] in
            let json = try await makeAPIRequest(bodyData: bodyData)
            return try OpenAIResponseParser.extractContent(from: json)
        }

        // Split response back into individual translations
        let translatedTexts: [String]
        if entries.count == 1 {
            translatedTexts = [content]
        } else {
            let recovered = ResponseRecovery.recover(
                combined: content,
                expectedCount: entries.count,
                separator: Constants.percentSeparatorWithNewlines
            )
            translatedTexts = ResponseRecovery.padOrTruncate(translations: recovered, entries: entries)
        }

        // Build result entries with translations
        return zip(entries, translatedTexts).map { entry, translation in
            var result = entry
            result.translatedText = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            return result
        }
    }

    private func makeAPIRequest(bodyData: Data) async throws -> [String: Any] {
        // Support base URLs with or without trailing /v1
        let base = baseURL.hasSuffix("/v1") ? baseURL : "\(baseURL)/v1"
        // `baseURL` is a free-text Settings field that auto-saves on every
        // keystroke, so a stray space or control character used to reach a
        // force-unwrapped `URL(string:)` and crash the app — persistently,
        // since the bad value was already on disk by then.
        guard let url = URL(string: "\(base)/chat/completions"), url.host != nil else {
            throw ScribeError.invalidConfig(
                field: "Base URL",
                reason: "\"\(baseURL)\" is not a valid URL"
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScribeError.translationFailed(
                engine: "OpenAI",
                underlying: NSError(domain: "HTTP", code: -1)
            )
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? ""

            if httpResponse.statusCode == 400 {
                if errorText.lowercased().contains("content_filter") ||
                   errorText.lowercased().contains("content management policy") {
                    throw ScribeError.contentFiltered
                }
            }

            if ScribeError.isRetryableHTTPStatus(httpResponse.statusCode) {
                throw ScribeError.rateLimited(retryAfter: nil)
            }

            throw ScribeError.translationFailed(
                engine: "OpenAI",
                underlying: NSError(domain: "OpenAI", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: errorText
                ])
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScribeError.translationParseFailed(rawResponse: String(data: data, encoding: .utf8) ?? "")
        }

        return json
    }
}

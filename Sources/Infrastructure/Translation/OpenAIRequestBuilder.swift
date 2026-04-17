import Foundation
import Domain

/// Pure functions for building OpenAI API request bodies.
///
/// SRP: Only responsible for request construction — no HTTP calls.
public enum OpenAIRequestBuilder {

    /// Build the JSON request body for a chat completion.
    /// - Parameters:
    ///   - texts: Array of subtitle texts to translate. If >1, joined with `%%` separator.
    ///   - model: Model ID (e.g., "gpt-4.1-nano").
    ///   - systemPrompt: The system prompt for translation instructions.
    /// - Returns: Dictionary suitable for JSON serialization.
    public static func buildRequestBody(
        texts: [String],
        model: String,
        systemPrompt: String
    ) -> [String: Any] {
        let textToTranslate: String
        if texts.count == 1 {
            textToTranslate = texts[0]
        } else {
            textToTranslate = texts.joined(separator: Constants.percentSeparatorWithNewlines)
        }

        let userPrompt = "Translate to Chinese (output translation only):\n\n\(textToTranslate)"

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": 0,
            "max_tokens": 8000,
        ]
    }
}

/// Pure functions for parsing OpenAI API responses.
public enum OpenAIResponseParser {

    /// Extract the translated content string from an API response.
    /// - Throws: `ScribeError.contentFiltered` or `.translationParseFailed`.
    public static func extractContent(from json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw ScribeError.translationParseFailed(rawResponse: String(describing: json))
        }

        let choice = choices[0]

        if let finishReason = choice["finish_reason"] as? String, finishReason == "content_filter" {
            throw ScribeError.contentFiltered
        }

        guard let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ScribeError.translationParseFailed(rawResponse: String(describing: json))
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

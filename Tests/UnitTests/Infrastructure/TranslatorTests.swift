import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Infrastructure

// MARK: - Test Doubles

/// Spy translator that records calls and returns preset results.
final class SpyTranslator: SubtitleTranslating, @unchecked Sendable {
    var translateCallCount = 0
    var lastEntries: [SubtitleEntry]?
    var stubbedResult: [SubtitleEntry] = []
    var shouldThrow: (any Error)?

    var name: String = "SpyTranslator"
    var isAvailable: Bool = true

    func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        translateCallCount += 1
        lastEntries = entries
        if let error = shouldThrow { throw error }
        return stubbedResult
    }
}

// MARK: - OpenAI Request Building Tests

@Suite("OpenAITranslator")
struct OpenAITranslatorTests {

    @Test("Builds correct request body for single entry")
    func requestBodySingleEntry() {
        let body = OpenAIRequestBuilder.buildRequestBody(
            texts: ["Hello world"],
            model: "gpt-4.1-nano",
            systemPrompt: "Translate to Chinese"
        )
        #expect(body["model"] as? String == "gpt-4.1-nano")
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[1]["role"] == "user")
        // Single entry should NOT have %% separator
        let userContent = messages?[1]["content"] ?? ""
        #expect(!userContent.contains("%%"))
    }

    @Test("Builds correct request body for multiple entries")
    func requestBodyMultipleEntries() {
        let body = OpenAIRequestBuilder.buildRequestBody(
            texts: ["Hello", "World", "Foo"],
            model: "gpt-4.1-nano",
            systemPrompt: "Translate"
        )
        let messages = body["messages"] as? [[String: String]]
        let userContent = messages?[1]["content"] ?? ""
        // Multiple entries should have %% separator
        #expect(userContent.contains("%%"))
    }

    @Test("Parses successful API response")
    func parseSuccessfulResponse() throws {
        let json: [String: Any] = [
            "choices": [
                [
                    "message": ["content": "你好%%世界"],
                    "finish_reason": "stop"
                ]
            ]
        ]
        let content = try OpenAIResponseParser.extractContent(from: json)
        #expect(content == "你好%%世界")
    }

    @Test("Throws contentFiltered on content_filter finish_reason")
    func contentFilterDetection() {
        let json: [String: Any] = [
            "choices": [
                [
                    "message": ["content": ""],
                    "finish_reason": "content_filter"
                ]
            ]
        ]
        #expect(throws: ScribeError.self) {
            try OpenAIResponseParser.extractContent(from: json)
        }
    }

    @Test("Throws on empty choices")
    func emptyChoices() {
        let json: [String: Any] = ["choices": [] as [Any]]
        #expect(throws: ScribeError.self) {
            try OpenAIResponseParser.extractContent(from: json)
        }
    }
}

// MARK: - FallbackTranslator Tests

@Suite("FallbackTranslator")
struct FallbackTranslatorTests {

    private func makeEntry(_ text: String) -> SubtitleEntry {
        SubtitleEntry(id: 1, timestamp: SubtitleTimestamp(start: 0, end: 1), text: text)
    }

    @Test("Uses primary translator when it succeeds")
    func usesPrimaryWhenAvailable() async throws {
        let primary = SpyTranslator()
        primary.stubbedResult = [makeEntry("translated")]
        let fallback = SpyTranslator()

        let translator = FallbackTranslator(primary: primary, fallback: fallback)
        let result = try await translator.translate(entries: [makeEntry("original")])

        #expect(primary.translateCallCount == 1)
        #expect(fallback.translateCallCount == 0)
        #expect(result[0].text == "translated")
    }

    @Test("Falls back to secondary when primary throws")
    func fallsBackOnPrimaryFailure() async throws {
        let primary = SpyTranslator()
        primary.shouldThrow = ScribeError.translationFailed(engine: "OpenAI", underlying: NSError(domain: "", code: 500))
        let fallback = SpyTranslator()
        fallback.stubbedResult = [makeEntry("fallback result")]

        let translator = FallbackTranslator(primary: primary, fallback: fallback)
        let result = try await translator.translate(entries: [makeEntry("original")])

        #expect(primary.translateCallCount == 1)
        #expect(fallback.translateCallCount == 1)
        #expect(result[0].text == "fallback result")
    }

    @Test("Returns original text when both translators fail")
    func returnsOriginalWhenBothFail() async throws {
        let primary = SpyTranslator()
        primary.shouldThrow = ScribeError.translationFailed(engine: "OpenAI", underlying: NSError(domain: "", code: 500))
        let fallback = SpyTranslator()
        fallback.shouldThrow = ScribeError.translationFailed(engine: "Google", underlying: NSError(domain: "", code: 500))

        let translator = FallbackTranslator(primary: primary, fallback: fallback)
        let entries = [makeEntry("original text")]
        let result = try await translator.translate(entries: entries)

        #expect(result[0].text == "original text")
    }

    @Test("Name includes both translator names")
    func nameIncludesBoth() {
        let primary = SpyTranslator()
        primary.name = "OpenAI"
        let fallback = SpyTranslator()
        fallback.name = "Google"
        let translator = FallbackTranslator(primary: primary, fallback: fallback)
        #expect(translator.name.contains("OpenAI"))
        #expect(translator.name.contains("Google"))
    }

    @Test("isAvailable when either translator is available")
    func availabilityCheck() {
        let primary = SpyTranslator()
        primary.isAvailable = false
        let fallback = SpyTranslator()
        fallback.isAvailable = true
        let translator = FallbackTranslator(primary: primary, fallback: fallback)
        #expect(translator.isAvailable)
    }
}

import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

/// `URLProtocol` stub that answers chat-completion requests without the
/// network. Each test uses its own host, so suites running in parallel
/// never see each other's requests.
final class StubChatProtocol: URLProtocol, @unchecked Sendable {

    /// Per-host status code and request counter.
    private struct Route { var status: Int; var requests: Int }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    /// Register a host and return a session whose requests it answers.
    static func session(host: String, status: Int) -> URLSession {
        lock.lock(); routes[host] = Route(status: status, requests: 0); lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubChatProtocol.self]
        return URLSession(configuration: config)
    }

    static func requestCount(host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return routes[host]?.requests ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.routes[host, default: Route(status: 404, requests: 0)].requests += 1
        let status = Self.routes[host]?.status ?? 404
        Self.lock.unlock()

        let body = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "translated"], "finish_reason": "stop"]],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The batching and retry settings must actually reach the translator.
/// They were persisted, and the batch sizes had Settings controls, but the
/// translator used hard-coded values — so these tests would all have failed.
@Suite("OpenAITranslator tuning")
struct OpenAITranslatorTuningTests {

    private func entries(_ count: Int) -> [SubtitleEntry] {
        (1 ... count).map {
            SubtitleEntry(id: $0, timestamp: SubtitleTimestamp(start: Double($0), end: Double($0) + 1), text: "line \($0)")
        }
    }

    private func makeTranslator(status: Int, tuning: TranslationTuning) -> (OpenAITranslator, String) {
        let host = "stub-\(UUID().uuidString.lowercased()).invalid"
        let translator = OpenAITranslator(
            apiKey: "sk-test",
            baseURL: "https://\(host)",
            tuning: tuning,
            session: StubChatProtocol.session(host: host, status: status)
        )
        return (translator, host)
    }

    @Test("maxEntriesPerBatch decides how many requests are sent")
    func entriesPerBatchIsHonoured() async throws {
        let (translator, host) = makeTranslator(
            status: 200,
            tuning: TranslationTuning(maxEntriesPerBatch: 2)
        )

        let result = try await translator.translate(entries: entries(5))

        #expect(StubChatProtocol.requestCount(host: host) == 3, "5 entries at 2 per batch is 3 requests")
        #expect(result.count == 5)
    }

    @Test("maxCharsPerBatch decides how many requests are sent")
    func charsPerBatchIsHonoured() async throws {
        // Each "line N" is 6 characters, so a 6-character budget forces one
        // entry per request.
        let (translator, host) = makeTranslator(
            status: 200,
            tuning: TranslationTuning(maxCharsPerBatch: 6, maxEntriesPerBatch: 100)
        )

        _ = try await translator.translate(entries: entries(4))

        #expect(StubChatProtocol.requestCount(host: host) == 4)
    }

    @Test("maxRetries decides how many times a retryable failure is attempted")
    func retriesAreHonoured() async {
        let (translator, host) = makeTranslator(
            status: 503,
            tuning: TranslationTuning(maxRetries: 2, retryBaseDelay: 0.001, retryMaxDelay: 0.001)
        )

        await #expect(throws: (any Error).self) {
            _ = try await translator.translate(entries: entries(1))
        }
        #expect(StubChatProtocol.requestCount(host: host) == 3, "1 attempt + 2 retries")
    }

    @Test("maxRetries of zero means a single attempt")
    func zeroRetriesMeansOneAttempt() async {
        let (translator, host) = makeTranslator(
            status: 503,
            tuning: TranslationTuning(maxRetries: 0, retryBaseDelay: 0.001, retryMaxDelay: 0.001)
        )

        await #expect(throws: (any Error).self) {
            _ = try await translator.translate(entries: entries(1))
        }
        #expect(StubChatProtocol.requestCount(host: host) == 1)
    }

    @Test("A negative stored retry count still makes one attempt")
    func negativeRetriesClamp() {
        #expect(TranslationTuning(maxRetries: -3).maxAttempts == 1)
    }

    @Test("AppConfig exposes its stored values as tuning")
    func configMapsToTuning() {
        let config = AppConfig(
            maxCharsPerBatch: 111, maxEntriesPerBatch: 22,
            maxRetries: 5, retryBaseDelay: 0.5, retryMaxDelay: 9
        )
        #expect(config.translationTuning == TranslationTuning(
            maxCharsPerBatch: 111, maxEntriesPerBatch: 22,
            maxRetries: 5, retryBaseDelay: 0.5, retryMaxDelay: 9
        ))
    }
}

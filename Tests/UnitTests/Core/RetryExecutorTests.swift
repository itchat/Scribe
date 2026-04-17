import Testing
import Foundation
@testable import Domain
@testable import Core

/// Thread-safe counter for testing retry behavior.
private final class CallCounter: @unchecked Sendable {
    private var _count = 0
    private let lock = NSLock()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
        return _count
    }
}

@Suite("RetryExecutor")
struct RetryExecutorTests {

    @Test("Succeeds on first attempt")
    func succeedsFirstAttempt() async throws {
        let counter = CallCounter()
        let result = try await RetryExecutor.execute(maxAttempts: 3, baseDelay: 0.01) {
            _ = counter.increment()
            return "success"
        }
        #expect(result == "success")
        #expect(counter.count == 1)
    }

    @Test("Retries on retryable error and eventually succeeds")
    func retriesAndSucceeds() async throws {
        let counter = CallCounter()
        let result: String = try await RetryExecutor.execute(
            maxAttempts: 3,
            baseDelay: 0.01,
            maxDelay: 0.02
        ) {
            let current = counter.increment()
            if current < 3 {
                throw ScribeError.rateLimited(retryAfter: nil)
            }
            return "recovered"
        }
        #expect(result == "recovered")
        #expect(counter.count == 3)
    }

    @Test("Does not retry non-retryable errors")
    func doesNotRetryNonRetryable() async {
        let counter = CallCounter()
        do {
            let _: String = try await RetryExecutor.execute(
                maxAttempts: 5,
                baseDelay: 0.01
            ) {
                _ = counter.increment()
                throw ScribeError.contentFiltered
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(counter.count == 1)
        }
    }

    @Test("Respects max attempts limit")
    func respectsMaxAttempts() async {
        let counter = CallCounter()
        do {
            let _: String = try await RetryExecutor.execute(
                maxAttempts: 3,
                baseDelay: 0.01,
                maxDelay: 0.02
            ) {
                _ = counter.increment()
                throw ScribeError.rateLimited(retryAfter: nil)
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(counter.count == 3)
        }
    }

    @Test("Custom shouldRetry closure overrides default behavior")
    func customShouldRetry() async {
        let counter = CallCounter()
        do {
            let _: String = try await RetryExecutor.execute(
                maxAttempts: 5,
                baseDelay: 0.01,
                shouldRetry: { _ in false }
            ) {
                _ = counter.increment()
                throw ScribeError.rateLimited(retryAfter: nil)
            }
            Issue.record("Should have thrown")
        } catch {
            #expect(counter.count == 1)
        }
    }
}

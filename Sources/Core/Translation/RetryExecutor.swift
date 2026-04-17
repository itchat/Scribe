import Foundation
import Domain

/// Generic retry executor with exponential backoff and jitter.
///
/// Replaces Python's 229-line `retry` decorator with a clean async/await implementation.
/// Uses `ScribeError.isRetryable` by default to determine retryability.
public enum RetryExecutor {

    /// Execute an async closure with retry logic.
    /// - Parameters:
    ///   - maxAttempts: Total attempts including the first (default: Constants.defaultMaxRetries + 1).
    ///   - baseDelay: Base delay in seconds for exponential backoff.
    ///   - maxDelay: Cap on the delay.
    ///   - jitterRange: Random jitter as a fraction of the computed delay.
    ///   - shouldRetry: Custom closure to decide retryability. Defaults to `ScribeError.isRetryable`.
    ///   - operation: The async throwing closure to execute.
    /// - Returns: The result of the operation.
    public static func execute<T>(
        maxAttempts: Int = Constants.defaultMaxRetries + 1,
        baseDelay: TimeInterval = Constants.defaultRetryBaseDelay,
        maxDelay: TimeInterval = Constants.defaultRetryMaxDelay,
        jitterRange: (min: Double, max: Double) = (0.1, 0.3),
        shouldRetry: ((any Error) -> Bool)? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        let retryCheck = shouldRetry ?? defaultShouldRetry
        var lastError: (any Error)?

        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Last attempt — don't retry
                if attempt == maxAttempts - 1 { break }

                // Check if retryable
                if !retryCheck(error) { break }

                // Exponential backoff + jitter
                let delay = calculateDelay(
                    attempt: attempt,
                    baseDelay: baseDelay,
                    maxDelay: maxDelay,
                    jitterRange: jitterRange
                )
                try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
        }

        throw lastError!
    }

    // MARK: - Private

    private static func defaultShouldRetry(_ error: any Error) -> Bool {
        if let vcError = error as? ScribeError {
            return vcError.isRetryable
        }
        return false
    }

    private static func calculateDelay(
        attempt: Int,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        jitterRange: (min: Double, max: Double)
    ) -> TimeInterval {
        let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
        let jitter = Double.random(in: jitterRange.min...jitterRange.max) * exponential
        return exponential + jitter
    }
}

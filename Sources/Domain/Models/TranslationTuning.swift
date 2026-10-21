import Foundation

/// How a translation engine batches requests and retries failures.
///
/// SOLID:
/// - **SRP**: pure value type — five numbers and their defaults, no I/O.
/// - **ISP**: translators take this instead of the whole `AppConfig`, so
///   they see only the settings that concern them.
///
/// These five values were stored in the config and the batch sizes even had
/// Settings controls, but the translator never read any of them: it used
/// `BatchSplitter`'s defaults and hard-coded its retry policy, so changing
/// them did nothing.
public struct TranslationTuning: Sendable, Equatable {
    public var maxCharsPerBatch: Int
    public var maxEntriesPerBatch: Int
    /// Retries after the first attempt; `0` means try once.
    public var maxRetries: Int
    public var retryBaseDelay: TimeInterval
    public var retryMaxDelay: TimeInterval

    public init(
        maxCharsPerBatch: Int = Constants.defaultMaxCharsPerBatch,
        maxEntriesPerBatch: Int = Constants.defaultMaxEntriesPerBatch,
        maxRetries: Int = Constants.defaultMaxRetries,
        retryBaseDelay: TimeInterval = Constants.defaultRetryBaseDelay,
        retryMaxDelay: TimeInterval = Constants.defaultRetryMaxDelay
    ) {
        self.maxCharsPerBatch = maxCharsPerBatch
        self.maxEntriesPerBatch = maxEntriesPerBatch
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.retryMaxDelay = retryMaxDelay
    }

    public static let `default` = TranslationTuning()

    /// Total attempts including the first, never below one — a stored
    /// negative retry count must not disable the request altogether.
    public var maxAttempts: Int { max(0, maxRetries) + 1 }
}

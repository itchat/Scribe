import Foundation

/// Unified error type for all Scribe failures.
///
/// Uses an enum instead of a class hierarchy (unlike the Python version's 19 exception classes).
/// Each case carries only the data needed for that specific error.
public enum ScribeError: LocalizedError, Equatable, Sendable {

    // MARK: - Audio

    case audioFileNotFound(URL)
    case noAudioStream(URL)
    case audioExtractionFailed(underlying: any Error)

    // MARK: - ASR

    case modelNotDownloaded
    case modelLoadFailed(underlying: any Error)
    case transcriptionFailed(underlying: any Error)

    // MARK: - Translation

    case translationFailed(engine: String, underlying: any Error)
    case contentFiltered
    case rateLimited(retryAfter: TimeInterval?)
    case translationParseFailed(rawResponse: String)

    // MARK: - Video Composition

    case subtitleFileInvalid(URL)
    case ffmpegNotFound
    case ffmpegFailed(stderr: String)
    case compositionTimeout

    // MARK: - Configuration

    case invalidConfig(field: String, reason: String)

    // MARK: - Retryability

    /// Whether this error is worth retrying (e.g., transient network issues).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .translationFailed:
            return true
        default:
            return false
        }
    }

    /// Whether an HTTP status code represents a retryable server error.
    public static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        [429, 500, 502, 503, 504].contains(statusCode)
    }

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .audioFileNotFound(let url):
            return "Audio file not found: \(url.lastPathComponent)"
        case .noAudioStream(let url):
            return "No audio stream in video: \(url.lastPathComponent)"
        case .audioExtractionFailed(let underlying):
            return "Audio extraction failed: \(underlying.localizedDescription)"
        case .modelNotDownloaded:
            return "ASR model has not been downloaded"
        case .modelLoadFailed(let underlying):
            return "Failed to load ASR model: \(underlying.localizedDescription)"
        case .transcriptionFailed(let underlying):
            return "Transcription failed: \(underlying.localizedDescription)"
        case .translationFailed(let engine, let underlying):
            return "Translation failed (\(engine)): \(underlying.localizedDescription)"
        case .contentFiltered:
            return "Content was filtered by the translation API's safety system"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited by API. Retry after \(Int(retryAfter)) seconds"
            }
            return "Rate limited by API"
        case .translationParseFailed(let rawResponse):
            return "Failed to parse translation response: \(rawResponse.prefix(100))"
        case .subtitleFileInvalid(let url):
            return "Invalid subtitle file: \(url.lastPathComponent)"
        case .ffmpegNotFound:
            return "FFmpeg not found. Please install FFmpeg"
        case .ffmpegFailed(let stderr):
            return "FFmpeg error: \(stderr.prefix(200))"
        case .compositionTimeout:
            return "Video composition timed out"
        case .invalidConfig(let field, let reason):
            return "Invalid configuration '\(field)': \(reason)"
        }
    }

    // MARK: - Equatable

    public static func == (lhs: ScribeError, rhs: ScribeError) -> Bool {
        switch (lhs, rhs) {
        case (.audioFileNotFound(let a), .audioFileNotFound(let b)):
            return a == b
        case (.noAudioStream(let a), .noAudioStream(let b)):
            return a == b
        case (.audioExtractionFailed, .audioExtractionFailed):
            return true
        case (.modelNotDownloaded, .modelNotDownloaded):
            return true
        case (.modelLoadFailed, .modelLoadFailed):
            return true
        case (.transcriptionFailed, .transcriptionFailed):
            return true
        case (.translationFailed(let e1, _), .translationFailed(let e2, _)):
            return e1 == e2
        case (.contentFiltered, .contentFiltered):
            return true
        case (.rateLimited(let a), .rateLimited(let b)):
            return a == b
        case (.translationParseFailed(let a), .translationParseFailed(let b)):
            return a == b
        case (.subtitleFileInvalid(let a), .subtitleFileInvalid(let b)):
            return a == b
        case (.ffmpegNotFound, .ffmpegNotFound):
            return true
        case (.ffmpegFailed(let a), .ffmpegFailed(let b)):
            return a == b
        case (.compositionTimeout, .compositionTimeout):
            return true
        case (.invalidConfig(let f1, let r1), .invalidConfig(let f2, let r2)):
            return f1 == f2 && r1 == r2
        default:
            return false
        }
    }
}

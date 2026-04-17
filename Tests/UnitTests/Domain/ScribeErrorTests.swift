import Testing
import Foundation
@testable import Domain

@Suite("ScribeError")
struct ScribeErrorTests {

    // MARK: - isRetryable

    @Test("rateLimited is retryable")
    func rateLimitedIsRetryable() {
        let error = ScribeError.rateLimited(retryAfter: 30)
        #expect(error.isRetryable)
    }

    @Test("translationFailed is retryable")
    func translationFailedIsRetryable() {
        let underlying = NSError(domain: "test", code: 500)
        let error = ScribeError.translationFailed(engine: "OpenAI", underlying: underlying)
        #expect(error.isRetryable)
    }

    @Test("contentFiltered is NOT retryable")
    func contentFilteredNotRetryable() {
        #expect(!ScribeError.contentFiltered.isRetryable)
    }

    @Test("ffmpegNotFound is NOT retryable")
    func ffmpegNotFoundNotRetryable() {
        #expect(!ScribeError.ffmpegNotFound.isRetryable)
    }

    @Test("modelNotDownloaded is NOT retryable")
    func modelNotDownloadedNotRetryable() {
        #expect(!ScribeError.modelNotDownloaded.isRetryable)
    }

    @Test("audioExtractionFailed is NOT retryable")
    func audioExtractionNotRetryable() {
        let underlying = NSError(domain: "test", code: 1)
        #expect(!ScribeError.audioExtractionFailed(underlying: underlying).isRetryable)
    }

    // MARK: - Error descriptions

    @Test("ffmpegNotFound has descriptive message")
    func ffmpegNotFoundDescription() {
        let error = ScribeError.ffmpegNotFound
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("FFmpeg"))
    }

    @Test("audioFileNotFound includes path info")
    func audioFileNotFoundIncludesPath() {
        let url = URL(filePath: "/tmp/test.mp4")
        let error = ScribeError.audioFileNotFound(url)
        #expect(error.errorDescription != nil)
    }

    @Test("rateLimited includes retry interval when present")
    func rateLimitedWithRetryAfter() {
        let error = ScribeError.rateLimited(retryAfter: 60)
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("60"))
    }

    @Test("rateLimited works without retry interval")
    func rateLimitedWithoutRetryAfter() {
        let error = ScribeError.rateLimited(retryAfter: nil)
        #expect(error.errorDescription != nil)
    }

    // MARK: - HTTP status retryability

    @Test("Retryable HTTP statuses", arguments: [429, 500, 502, 503, 504])
    func retryableHTTPStatuses(statusCode: Int) {
        #expect(ScribeError.isRetryableHTTPStatus(statusCode))
    }

    @Test("Non-retryable HTTP statuses", arguments: [400, 401, 403, 404])
    func nonRetryableHTTPStatuses(statusCode: Int) {
        #expect(!ScribeError.isRetryableHTTPStatus(statusCode))
    }
}

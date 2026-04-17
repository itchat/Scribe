import Testing
import Foundation
@testable import Domain

@Suite("ProcessingOptions")
struct ProcessingOptionsTests {

    @Test("Default options have translation and burning enabled")
    func defaults() {
        let options = ProcessingOptions()
        #expect(!options.skipTranslation)
        #expect(!options.skipSubtitleBurning)
        #expect(options.translationEngine == .openAI)
    }

    @Test("Custom options preserve values")
    func customOptions() {
        let options = ProcessingOptions(
            skipTranslation: true,
            skipSubtitleBurning: true,
            translationEngine: .google
        )
        #expect(options.skipTranslation)
        #expect(options.skipSubtitleBurning)
        #expect(options.translationEngine == .google)
    }
}

@Suite("ProcessingResult")
struct ProcessingResultTests {

    @Test("Completed result has output paths")
    func completedResult() {
        let result = ProcessingResult(
            status: .completed,
            outputVideoURL: URL(filePath: "/tmp/out.mp4"),
            subtitleURL: URL(filePath: "/tmp/out.srt"),
            originalSubtitleURL: URL(filePath: "/tmp/out_en.srt")
        )
        #expect(result.outputVideoURL != nil)
        #expect(result.subtitleURL != nil)
    }

    @Test("Failed result has no output paths")
    func failedResult() {
        let result = ProcessingResult(status: .failed(.ffmpegNotFound))
        if case .failed(let error) = result.status {
            #expect(error == .ffmpegNotFound)
        } else {
            Issue.record("Expected failed status")
        }
    }

    @Test("Skipped result carries reason")
    func skippedResult() {
        let result = ProcessingResult(status: .skipped(reason: "Empty audio"))
        if case .skipped(let reason) = result.status {
            #expect(reason == "Empty audio")
        } else {
            Issue.record("Expected skipped status")
        }
    }

    @Test("isSuccess returns true only for completed")
    func isSuccess() {
        let completed = ProcessingResult(status: .completed)
        let failed = ProcessingResult(status: .failed(.ffmpegNotFound))
        let skipped = ProcessingResult(status: .skipped(reason: "test"))
        #expect(completed.isSuccess)
        #expect(!failed.isSuccess)
        #expect(!skipped.isSuccess)
    }
}

@Suite("TranslationEngine")
struct TranslationEngineTests {

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        let original = TranslationEngine.openAI
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranslationEngine.self, from: data)
        #expect(decoded == original)
    }

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(TranslationEngine.openAI.rawValue == "OpenAI")
        #expect(TranslationEngine.google.rawValue == "Google")
    }
}

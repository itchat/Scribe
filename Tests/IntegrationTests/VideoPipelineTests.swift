import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Core
@testable import Infrastructure

// MARK: - Test Doubles

final class FakeAudioExtractor: AudioExtracting, @unchecked Sendable {
    var extractCallCount = 0
    var shouldThrow: (any Error)?

    func extract(from videoURL: URL, to outputURL: URL) async throws {
        extractCallCount += 1
        if let error = shouldThrow { throw error }
        // Create a small file to simulate audio
        try Data(repeating: 0, count: 2000).write(to: outputURL)
    }
}

final class FakeSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    var transcribeCallCount = 0
    var stubbedResult = TranscriptionResult(
        text: "Hello world. How are you.",
        segments: [
            TranscriptionSegment(text: "Hello world.", start: 0.0, end: 2.5),
            TranscriptionSegment(text: "How are you.", start: 3.0, end: 5.0),
        ]
    )

    func transcribe(audioAt url: URL, progress: (any Protocols.ProgressReporting)?) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        progress?.reportProgress(50)
        return stubbedResult
    }
}

final class FakeTranslator: SubtitleTranslating, @unchecked Sendable {
    var translateCallCount = 0
    var name: String = "FakeTranslator"
    var isAvailable: Bool = true

    func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] {
        translateCallCount += 1
        return entries.map { entry in
            var e = entry
            e.translatedText = "翻译: \(entry.text)"
            return e
        }
    }
}

final class FakeVideoComposer: VideoComposing, @unchecked Sendable {
    var composeCallCount = 0

    func compose(video: URL, subtitles: URL, output: URL, progress: (any Protocols.ProgressReporting)?) async throws {
        composeCallCount += 1
        // Create a fake output file
        try Data(repeating: 0, count: 100).write(to: output)
        progress?.reportProgress(100)
    }
}

final class SpyProgressReporter: Protocols.ProgressReporting, @unchecked Sendable {
    var progressValues: [Int] = []
    var statusMessages: [String] = []

    func reportProgress(_ percent: Int) { progressValues.append(percent) }
    func reportStatus(_ message: String) { statusMessages.append(message) }
}

// MARK: - Pipeline Tests

@Suite("VideoPipeline")
struct VideoPipelineTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFakeVideo(in dir: URL) throws -> URL {
        let videoURL = dir.appendingPathComponent("test_video.mp4")
        try Data(repeating: 0, count: 100).write(to: videoURL)
        return videoURL
    }

    @Test("Full pipeline calls all steps in order")
    func fullPipelineCallsAllSteps() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = try makeFakeVideo(in: dir)

        let extractor = FakeAudioExtractor()
        let recognizer = FakeSpeechRecognizer()
        let translator = FakeTranslator()
        let composer = FakeVideoComposer()
        let formatter = SubtitleFormatter()
        let progress = SpyProgressReporter()

        let pipeline = VideoPipeline(
            videoURL: videoURL,
            cacheDir: dir,
            options: ProcessingOptions(),
            audioExtractor: extractor,
            speechRecognizer: recognizer,
            translator: translator,
            videoComposer: composer,
            subtitleFormatter: formatter,
            progress: progress
        )

        let result = await pipeline.process()

        #expect(result.isSuccess)
        #expect(extractor.extractCallCount == 1)
        #expect(recognizer.transcribeCallCount == 1)
        #expect(translator.translateCallCount == 1)
        #expect(composer.composeCallCount == 1)
    }

    @Test("Pipeline skips translation when option is set")
    func skipsTranslation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = try makeFakeVideo(in: dir)

        let translator = FakeTranslator()
        let composer = FakeVideoComposer()

        let pipeline = VideoPipeline(
            videoURL: videoURL,
            cacheDir: dir,
            options: ProcessingOptions(skipTranslation: true),
            audioExtractor: FakeAudioExtractor(),
            speechRecognizer: FakeSpeechRecognizer(),
            translator: translator,
            videoComposer: composer,
            subtitleFormatter: SubtitleFormatter(),
            progress: nil
        )

        let result = await pipeline.process()

        #expect(result.isSuccess)
        #expect(translator.translateCallCount == 0)
        #expect(composer.composeCallCount == 0)
        #expect(result.subtitleURL != nil)
    }

    @Test("Pipeline skips burning when option is set")
    func skipsBurning() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = try makeFakeVideo(in: dir)

        let composer = FakeVideoComposer()

        let pipeline = VideoPipeline(
            videoURL: videoURL,
            cacheDir: dir,
            options: ProcessingOptions(skipSubtitleBurning: true),
            audioExtractor: FakeAudioExtractor(),
            speechRecognizer: FakeSpeechRecognizer(),
            translator: FakeTranslator(),
            videoComposer: composer,
            subtitleFormatter: SubtitleFormatter(),
            progress: nil
        )

        let result = await pipeline.process()

        #expect(result.isSuccess)
        #expect(composer.composeCallCount == 0)
        #expect(result.subtitleURL != nil)
    }

    @Test("Pipeline reports progress at each stage")
    func reportsProgress() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = try makeFakeVideo(in: dir)
        let progress = SpyProgressReporter()

        let pipeline = VideoPipeline(
            videoURL: videoURL,
            cacheDir: dir,
            options: ProcessingOptions(),
            audioExtractor: FakeAudioExtractor(),
            speechRecognizer: FakeSpeechRecognizer(),
            translator: FakeTranslator(),
            videoComposer: FakeVideoComposer(),
            subtitleFormatter: SubtitleFormatter(),
            progress: progress
        )

        _ = await pipeline.process()

        // Should have received multiple progress updates
        #expect(!progress.progressValues.isEmpty)
        // Should have received status messages
        #expect(!progress.statusMessages.isEmpty)
    }

    @Test("Pipeline returns error result on extraction failure")
    func handlesExtractionFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = try makeFakeVideo(in: dir)

        let extractor = FakeAudioExtractor()
        extractor.shouldThrow = ScribeError.audioExtractionFailed(
            underlying: NSError(domain: "test", code: 1)
        )

        let pipeline = VideoPipeline(
            videoURL: videoURL,
            cacheDir: dir,
            options: ProcessingOptions(),
            audioExtractor: extractor,
            speechRecognizer: FakeSpeechRecognizer(),
            translator: FakeTranslator(),
            videoComposer: FakeVideoComposer(),
            subtitleFormatter: SubtitleFormatter(),
            progress: nil
        )

        let result = await pipeline.process()
        #expect(!result.isSuccess)
    }
}

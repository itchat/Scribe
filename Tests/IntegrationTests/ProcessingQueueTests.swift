import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Core

// Reuse test doubles from VideoPipelineTests (same target)

@Suite("ProcessingQueue")
struct ProcessingQueueTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("queue_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFakeVideo(in dir: URL, name: String = "test.mp4") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: 100).write(to: url)
        return url
    }

    @Test("Processes videos sequentially")
    func processesSequentially() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1 = try makeFakeVideo(in: dir, name: "video1.mp4")
        let v2 = try makeFakeVideo(in: dir, name: "video2.mp4")

        let extractor = FakeAudioExtractor()
        let recognizer = FakeSpeechRecognizer()
        let translator = FakeTranslator()
        let composer = FakeVideoComposer()
        let formatter = SubtitleFormatter()

        let queue = ProcessingQueue { videoURL, progress in
            VideoPipeline(
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
        }

        let results = await queue.processAll([v1, v2])
        #expect(results.count == 2)
        #expect(results[0].isSuccess)
        #expect(results[1].isSuccess)
        // Both videos processed = 2 extract calls
        #expect(extractor.extractCallCount == 2)
    }

    @Test("Continues after single file error")
    func continuesAfterError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1 = try makeFakeVideo(in: dir, name: "video1.mp4")
        let v2 = try makeFakeVideo(in: dir, name: "video2.mp4")

        let counter = CallCounter()

        let queue = ProcessingQueue { videoURL, progress in
            let extractor = FakeAudioExtractor()
            let current = counter.increment()
            if current == 1 {
                extractor.shouldThrow = ScribeError.audioExtractionFailed(
                    underlying: NSError(domain: "test", code: 1)
                )
            }
            return VideoPipeline(
                videoURL: videoURL,
                cacheDir: dir,
                options: ProcessingOptions(),
                audioExtractor: extractor,
                speechRecognizer: FakeSpeechRecognizer(),
                translator: FakeTranslator(),
                videoComposer: FakeVideoComposer(),
                subtitleFormatter: SubtitleFormatter(),
                progress: progress
            )
        }

        let results = await queue.processAll([v1, v2])
        #expect(results.count == 2)
        #expect(!results[0].isSuccess) // first failed
        #expect(results[1].isSuccess)  // second succeeded
    }
}

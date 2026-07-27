import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Core
@testable import Infrastructure

/// The pipeline end to end: video in → SRT on disk → burned video out.
///
/// Nothing previously covered this. `VideoPipelineTests` exercises the
/// orchestration against four fakes, so the entire ffmpeg surface — command
/// construction *as executed*, libass styling, ffprobe-derived dimensions —
/// had no execution coverage at all. Both of the correctness bugs fixed in
/// this branch lived in exactly that gap and survived a green suite.
///
/// The ASR model is deliberately faked: this test is about the ffmpeg half,
/// and keeping models out keeps it fast enough for CI.
@Suite("PipelineE2E")
struct PipelineE2ETests {

    private static var fixturesDir: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private static var sampleVideo: URL { fixturesDir.appendingPathComponent("sample.mp4") }

    private static var canRun: Bool {
        FFmpegLocator.find() != nil
            && FileManager.default.fileExists(atPath: sampleVideo.path)
    }

    /// Returns fixed segments so the pipeline's output is deterministic.
    private struct StubRecognizer: SpeechRecognizing {
        func transcribe(
            audioAt url: URL,
            progress: (any Protocols.ProgressReporting)?
        ) async throws -> TranscriptionResult {
            let segments = [
                TranscriptionSegment(text: "First caption line.", start: 0.0, end: 1.2),
                TranscriptionSegment(text: "Second caption line.", start: 1.2, end: 2.4),
            ]
            return TranscriptionResult(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments
            )
        }
    }

    /// Translation is skipped in these tests, but the pipeline requires a
    /// non-optional collaborator, so hand it one that changes nothing.
    private struct PassthroughTranslator: SubtitleTranslating {
        var name: String { "Passthrough" }
        var isAvailable: Bool { true }
        func translate(entries: [SubtitleEntry]) async throws -> [SubtitleEntry] { entries }
    }

    private func expectCompleted(_ result: ProcessingResult) {
        if case .completed = result.status { return }
        Issue.record("pipeline did not complete: \(result.status)")
    }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-pipeline-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies the fixture under a name full of filtergraph metacharacters, so
    /// the whole pipeline — SRT path derivation included — is exercised with
    /// the input that used to break it. The SRT sidecar is named after the
    /// video, so a hostile video name produces a hostile subtitle path.
    @Test("Burns a video whose name contains filtergraph metacharacters",
          .enabled(if: canRun),
          .timeLimit(.minutes(5)))
    func endToEndWithHostileName() async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let hostileName = "Lecture [1080p] John's talk, part 2.mp4"
        let input = workDir.appendingPathComponent(hostileName)
        try FileManager.default.copyItem(at: Self.sampleVideo, to: input)

        let pipeline = VideoPipeline(
            videoURL: input,
            cacheDir: workDir,
            options: ProcessingOptions(
                skipTranslation: true,
                skipSubtitleBurning: false,
                subtitleStyle: SubtitleStyle()
            ),
            audioExtractor: try FFmpegAudioExtractor(),
            speechRecognizer: StubRecognizer(),
            translator: PassthroughTranslator(),
            videoComposer: try FFmpegVideoComposer(),
            subtitleFormatter: SubtitleFormatter(),
            progress: nil
        )

        let result = await pipeline.process()

        expectCompleted(result)

        // SRT sidecar exists and round-trips through the parser.
        let srtURL = try #require(result.subtitleURL, "pipeline produced no SRT")
        #expect(FileManager.default.fileExists(atPath: srtURL.path))
        let srtText = try String(contentsOf: srtURL, encoding: .utf8)
        let cues = try SRTParser.parse(srtText)
        #expect(cues.count == 2, "expected 2 cues, got \(cues.count)")
        #expect(cues.first?.text.contains("First caption line") == true)

        // Burned video exists and is non-trivial.
        let outputURL = try #require(result.outputVideoURL, "pipeline produced no video")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let size = (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        #expect(size > 1000, "burned video is suspiciously small (\(size) bytes)")
    }

    /// With burning skipped the pipeline must still produce a valid sidecar
    /// and must not produce a video.
    @Test("Produces only an SRT when burning is skipped",
          .enabled(if: canRun),
          .timeLimit(.minutes(5)))
    func srtOnly() async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let input = workDir.appendingPathComponent("plain.mp4")
        try FileManager.default.copyItem(at: Self.sampleVideo, to: input)

        let pipeline = VideoPipeline(
            videoURL: input,
            cacheDir: workDir,
            options: ProcessingOptions(
                skipTranslation: true,
                skipSubtitleBurning: true,
                subtitleStyle: SubtitleStyle()
            ),
            audioExtractor: try FFmpegAudioExtractor(),
            speechRecognizer: StubRecognizer(),
            translator: PassthroughTranslator(),
            videoComposer: try FFmpegVideoComposer(),
            subtitleFormatter: SubtitleFormatter(),
            progress: nil
        )

        let result = await pipeline.process()
        expectCompleted(result)
        let srtURL = try #require(result.subtitleURL)
        let text = try String(contentsOf: srtURL, encoding: .utf8)
        #expect(try SRTParser.parse(text).count == 2)
    }
}

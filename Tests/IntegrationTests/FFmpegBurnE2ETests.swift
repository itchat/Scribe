import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// End-to-end exercise of the ffmpeg burn path against real binaries and a
/// tiny committed fixture.
///
/// This is the coverage gap that let two real bugs ship: `FFmpegVideoComposer`
/// had never been instantiated by any test, and `FFmpegCommandBuilder` was
/// only ever checked as string building, so an escaping scheme that ffmpeg
/// rejects still looked correct. Both are cheap to catch by actually running
/// a three-second burn.
///
/// No ASR model is involved, so this stays fast enough for CI.
@Suite("FFmpegBurnE2E")
struct FFmpegBurnE2ETests {

    // MARK: - Fixtures

    private static var fixturesDir: URL {
        URL(filePath: #filePath)            // …/Tests/IntegrationTests/<this file>
            .deletingLastPathComponent()    // …/Tests/IntegrationTests
            .deletingLastPathComponent()    // …/Tests
            .appendingPathComponent("Fixtures")
    }

    private static var sampleVideo: URL { fixturesDir.appendingPathComponent("sample.mp4") }
    private static var silentVideo: URL { fixturesDir.appendingPathComponent("silent.mp4") }

    private static var canRun: Bool {
        FFmpegLocator.find() != nil
            && FileManager.default.fileExists(atPath: sampleVideo.path)
    }

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-burn-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSRT(at url: URL) throws {
        try """
        1
        00:00:00,000 --> 00:00:02,000
        hello world

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Burn

    /// Every one of these names round-trips through the filtergraph. The
    /// apostrophe case is the regression: it previously reached libass with
    /// the quote stripped, so the file could not be opened and the burn
    /// failed for any user whose filename contained one.
    @Test("Burns subtitles for filenames containing filtergraph metacharacters",
          .enabled(if: canRun),
          .timeLimit(.minutes(5)),
          arguments: [
            "plain",
            "Lecture [1080p]",
            "John's talk",
            "a:colon",
            "with space",
            "comma,and;semi",
            "equals=sign",
          ])
    func burnsWithHostileFilenames(stem: String) async throws {
        let workDir = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let srt = workDir.appendingPathComponent("\(stem).srt")
        try writeSRT(at: srt)

        let output = workDir.appendingPathComponent("out-\(UUID().uuidString).mp4")
        let composer = try FFmpegVideoComposer()

        try await composer.compose(
            video: Self.sampleVideo,
            subtitles: srt,
            output: output,
            style: SubtitleStyle(),
            progress: nil
        )

        #expect(FileManager.default.fileExists(atPath: output.path),
                "burn produced no output for filename stem \(stem)")
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        #expect(size > 0, "burn produced an empty file for filename stem \(stem)")
    }

    // MARK: - ffprobe-backed behaviour

    /// Directly exercises the ffprobe path derivation. Under the previous
    /// string-substitution the probe binary did not exist on any host using
    /// Homebrew's `ffmpeg-full`, so `hasAudioStream` hit its catch branch
    /// and returned `true` unconditionally — silent-video detection was
    /// dead exactly where it was needed.
    @Test("Detects presence and absence of an audio stream", .enabled(if: canRun))
    func detectsAudioStream() async throws {
        let probe = try FFmpegAudioProbe()
        #expect(try await probe.hasAudioStream(in: Self.sampleVideo) == true)
        #expect(try await probe.hasAudioStream(in: Self.silentVideo) == false,
                "silent.mp4 has no audio track; a false positive means ffprobe is not running")
    }

    /// `duration` falls back to a file-size estimate when ffprobe fails, so
    /// a wrong probe path yields a wildly wrong number rather than an error.
    /// The fixture is 3 s; the estimate for a 22 KB mp4 would be far off.
    @Test("Reports fixture duration from ffprobe rather than the size fallback",
          .enabled(if: canRun))
    func reportsRealDuration() async throws {
        let probe = try FFmpegAudioProbe()
        let duration = try await probe.duration(of: Self.sampleVideo)
        #expect(abs(duration - 3.0) < 0.5, "expected ~3s, got \(duration)")
    }
}

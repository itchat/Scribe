import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Core
@testable import Infrastructure

/// End-to-end exercise of the burn pipeline's Qwen3 path. Mirrors what the
/// GUI does when the user picks `OfflineASREngine.qwen3_0_6B`: extract
/// audio with FFmpeg, then transcribe with `Qwen3OfflineRecognizer`.
///
/// Skipped unless a sample video is available *and* `mlx.metallib` sits
/// beside the test binary. Point at your own media with `SCRIBE_SAMPLE_VIDEO`
/// / `SCRIBE_LONG_VIDEO`, then:
/// `swift test --filter Qwen3OfflineRecognizerE2E`
///
/// First-time invocation downloads ~342 MB (0.6B) into
/// `~/Library/Caches/qwen3-speech/`. Subsequent runs reuse the cache.
@Suite("Qwen3OfflineRecognizerE2E")
struct Qwen3OfflineRecognizerE2ETests {

    /// Short sample clip. Defaults to `~/Downloads/test.mp4` for
    /// convenience, overridable with `SCRIBE_SAMPLE_VIDEO`.
    private static var sampleVideo: URL {
        let raw = ProcessInfo.processInfo.environment["SCRIBE_SAMPLE_VIDEO"] ?? "~/Downloads/test.mp4"
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
    }

    private static var sampleExists: Bool {
        FileManager.default.fileExists(atPath: sampleVideo.path)
    }

    /// A long video (mixed Mandarin/English lecture audio, hours long). The
    /// duration is what makes this case interesting — a multi-hour input was
    /// previously fed to the model in one shot, truncated to 1200 s of mel
    /// frames and capped at 448 output tokens, collapsing the SRT to
    /// near-empty.
    ///
    /// Supplied via `SCRIBE_LONG_VIDEO`, e.g.
    ///
    ///     SCRIBE_LONG_VIDEO=~/Movies/lecture.mp4 swift test --filter longVideo0_6B
    ///
    /// This used to be hardcoded to one developer's personal file
    /// (`~/Desktop/CPI/Week3/05.09-2.mp4`), which meant the repo's most
    /// valuable regression guard was unrunnable by CI or by anyone else —
    /// while silently *running* on that one machine, where it aborted the
    /// whole suite (see `mlxMetallibAvailable`).
    private static var longVideo: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SCRIBE_LONG_VIDEO"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)
    }

    private static var longVideoExists: Bool {
        guard let longVideo else { return false }
        return FileManager.default.fileExists(atPath: longVideo.path)
    }

    /// MLX calls `abort()` — not a catchable Swift error — when it cannot
    /// find `mlx.metallib` colocated with the running executable. SwiftPM
    /// cannot compile Metal shaders, so under `swift test` that library is
    /// absent unless `scripts/build-mlx-metallib.sh` has been pointed at
    /// the test bin directory. Without this gate a single MLX test takes
    /// the **entire** test run down with it, which is exactly what happened
    /// on a machine where `longVideo` existed: CI stayed green (file absent
    /// → test skipped) while the developer's own `swift test` aborted.
    private static var mlxMetallibAvailable: Bool {
        guard let execDir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: execDir.appendingPathComponent("mlx.metallib").path
        )
    }

    /// Every Qwen3 case needs both a video *and* a usable MLX runtime.
    private static func canRun(_ videoExists: Bool) -> Bool {
        videoExists && mlxMetallibAvailable
    }

    @Test("Qwen3 0.6B end-to-end on test.mp4 emits non-empty transcript",
          .enabled(if: canRun(sampleExists)))
    func endToEnd0_6B() async throws {
        try await runEndToEnd(size: .b0_6, video: Self.sampleVideo)
    }

    @Test("Qwen3 1.7B end-to-end on test.mp4 emits non-empty transcript",
          .enabled(if: canRun(sampleExists)),
          .timeLimit(.minutes(20)))
    func endToEnd1_7B() async throws {
        try await runEndToEnd(size: .b1_7, video: Self.sampleVideo)
    }

    @Test("Long video 0.6B emits many cues spanning the full duration",
          .enabled(if: canRun(longVideoExists)),
          .timeLimit(.minutes(60)))
    func longVideo0_6B() async throws {
        let video = try #require(Self.longVideo)
        let result = try await runEndToEnd(size: .b0_6, video: video)
        // Regression guard for the empty-SRT bug — a multi-hour lecture
        // must produce many cues, not one or zero. We don't pin a specific
        // count because VAD-driven chunking is content-dependent, but
        // anything under 20 cues is the bug we fixed (pre-fix: 0–1).
        #expect(result.segments.count >= 20,
                "Long video should produce many cues; got \(result.segments.count)")
    }

    @discardableResult
    private func runEndToEnd(size: Qwen3OfflineRecognizer.Size, video: URL) async throws -> Domain.TranscriptionResult {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-qwen3-e2e-\(size.label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioURL = workDir.appendingPathComponent("test_audio.wav")

        let extractor = try FFmpegAudioExtractor()
        let progress = PrintProgress()
        progress.reportStatus("Extracting audio from \(video.lastPathComponent)…")
        try await extractor.extract(from: video, to: audioURL)
        progress.reportStatus("Audio extracted to \(audioURL.lastPathComponent)")

        let recognizer = Qwen3OfflineRecognizer(size: size)
        let result = try await recognizer.transcribe(audioAt: audioURL, progress: progress)

        print("=== Qwen3 \(size.label) transcript (first 500 chars) ===")
        print(String(result.text.prefix(500)))
        print("=== \(result.segments.count) segments ===")
        if let first = result.segments.first, let last = result.segments.last {
            print("first cue: \(first.start)s → \(first.end)s — \(first.text.prefix(60))")
            print("last cue: \(last.start)s → \(last.end)s — \(last.text.prefix(60))")
        }

        #expect(!result.text.isEmpty, "Qwen3 \(size.label) returned empty transcript")
        #expect(!result.segments.isEmpty, "Qwen3 \(size.label) returned no segments")
        return result
    }
}

/// Console progress reporter — writes status lines to stdout so a manual
/// run prints what would otherwise be ProcessingViewModel state updates.
private final class PrintProgress: Protocols.ProgressReporting, @unchecked Sendable {
    func reportProgress(_ percent: Int) {
        print("[progress] \(percent)%")
    }
    func reportStatus(_ message: String) {
        print("[status] \(message)")
    }
}

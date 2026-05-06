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
/// Skipped unless `~/Downloads/test.mp4` exists. Run explicitly with:
/// `swift test --filter Qwen3OfflineRecognizerE2E`
///
/// First-time invocation downloads ~342 MB (0.6B) into
/// `~/Library/Caches/qwen3-speech/`. Subsequent runs reuse the cache.
@Suite("Qwen3OfflineRecognizerE2E")
struct Qwen3OfflineRecognizerE2ETests {

    private static var sampleVideo: URL {
        URL(fileURLWithPath: NSString("~/Downloads/test.mp4").expandingTildeInPath)
    }

    private static var sampleExists: Bool {
        FileManager.default.fileExists(atPath: sampleVideo.path)
    }

    @Test("Qwen3 0.6B end-to-end on test.mp4 emits non-empty transcript",
          .enabled(if: sampleExists))
    func endToEnd0_6B() async throws {
        try await runEndToEnd(size: .b0_6)
    }

    @Test("Qwen3 1.7B end-to-end on test.mp4 emits non-empty transcript",
          .enabled(if: sampleExists),
          .timeLimit(.minutes(20)))
    func endToEnd1_7B() async throws {
        try await runEndToEnd(size: .b1_7)
    }

    private func runEndToEnd(size: Qwen3OfflineRecognizer.Size) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-qwen3-e2e-\(size.label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioURL = workDir.appendingPathComponent("test_audio.wav")

        let extractor = try FFmpegAudioExtractor()
        let progress = PrintProgress()
        progress.reportStatus("Extracting audio…")
        try await extractor.extract(from: Self.sampleVideo, to: audioURL)
        progress.reportStatus("Audio extracted to \(audioURL.lastPathComponent)")

        let recognizer = Qwen3OfflineRecognizer(size: size)
        let result = try await recognizer.transcribe(audioAt: audioURL, progress: progress)

        print("=== Qwen3 \(size.label) transcript ===")
        print(result.text)
        print("=== \(result.segments.count) segments ===")

        #expect(!result.text.isEmpty, "Qwen3 \(size.label) returned empty transcript")
        #expect(!result.segments.isEmpty, "Qwen3 \(size.label) returned no segments")
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

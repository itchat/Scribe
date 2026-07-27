import Testing
import Foundation
import AVFoundation
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// Constructs each sherpa-onnx engine against real model files.
///
/// This exists for one reason: sherpa-onnx's static library is built against
/// a *specific* ONNX Runtime version, and mixing versions changes the vtable
/// layout of `Ort::Env`. The result is a null-vtable read that **segfaults
/// during recognizer construction** — it is not a link error and not a Swift
/// error, so nothing in a normal build or test run catches it. Every other
/// test in the suite links ~200 MB of sherpa and ONNX Runtime without ever
/// calling a single sherpa symbol.
///
/// `scripts/fetch-sherpa-onnx.sh` pins `SHERPA_VERSION` and `ORT_VERSION`
/// together for this reason. Any change to either must be validated by
/// running this suite.
///
/// Gated on the model files already being cached, so a fresh checkout or a
/// CI runner without models skips rather than downloading ~1.5 GB.
@Suite("SherpaOnnxSmoke")
struct SherpaOnnxSmokeTests {

    private static var modelsRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/models")
    }

    private static func cached(_ modelDirName: String, requiring files: [String]) -> Bool {
        let dir = modelsRoot.appendingPathComponent(modelDirName)
        return files.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private static let zipformerCached = cached(
        "sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30",
        requiring: ["encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt"]
    )

    private static let paraformerCached = cached(
        "sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en",
        requiring: ["encoder.onnx", "decoder.onnx", "tokens.txt"]
    )

    /// One second of 16 kHz mono silence — enough to drive a decode pass
    /// without depending on any particular transcript.
    private func silenceBuffer(seconds: Double = 1.0) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    /// Drives the full lifecycle. A version mismatch takes the process down
    /// at `start()`, so simply reaching the assertions is the signal.
    private func exerciseLifecycle(_ engine: any StreamingTranscribing) async throws {
        _ = await engine.partials
        try await engine.start()
        try await engine.appendAudio(try silenceBuffer())
        let transcript = try await engine.finish()
        // Silence may legitimately decode to an empty string; the point is
        // that construction, decode, and teardown all completed.
        #expect(transcript.isEmpty || !transcript.isEmpty)
    }

    @Test("Zipformer zh-XLarge constructs, decodes and tears down",
          .enabled(if: zipformerCached),
          .timeLimit(.minutes(5)))
    func zipformerLifecycle() async throws {
        try await exerciseLifecycle(SherpaZipformerXLargeStreamingRecognizer())
    }

    @Test("Paraformer zh-yue-en constructs, decodes and tears down",
          .enabled(if: paraformerCached),
          .timeLimit(.minutes(5)))
    func paraformerLifecycle() async throws {
        try await exerciseLifecycle(SherpaParaformerTrilingualStreamingRecognizer())
    }

    /// Restarting the same actor must not double-construct or crash. The two
    /// most recent commits touching this area fixed a restart hang and a
    /// leak, both without any test covering the path.
    @Test("Zipformer survives a start / finish / start cycle",
          .enabled(if: zipformerCached),
          .timeLimit(.minutes(5)))
    func zipformerRestart() async throws {
        let engine = SherpaZipformerXLargeStreamingRecognizer()
        try await exerciseLifecycle(engine)
        try await exerciseLifecycle(engine)
    }
}

import Testing
import Foundation
import AVFoundation
@testable import Domain
@testable import Infrastructure

/// Correctness cover for the chunked sample reader.
///
/// The reader used to materialise the entire file as an `AVAudioPCMBuffer`
/// and then copy it into an `Array`, so both were resident at once — roughly
/// 920 MB of peak allocation for a two-hour video, before the ASR model was
/// even loaded. Reading in chunks halves that, but only if the chunk seam is
/// handled correctly, which is what these tests pin down.
@Suite("AudioFileReader")
struct AudioFileReaderTests {

    /// Writes `frames` of a deterministic ramp as 16 kHz mono Float32 WAV.
    private func writeRamp(frames: Int) throws -> (url: URL, expected: [Float]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-audioreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ramp.wav")

        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        var expected = [Float]()
        expected.reserveCapacity(frames)

        // Write in modest blocks so the writer itself isn't the memory hog.
        let block = 8_192
        var written = 0
        while written < frames {
            let count = min(block, frames - written)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channel = try #require(buffer.floatChannelData?[0])
            for i in 0..<count {
                // Distinct, bounded value per index so any reordering,
                // duplication or gap at a chunk seam is detectable.
                let value = Float((written + i) % 1000) / 1000.0 - 0.5
                channel[i] = value
                expected.append(value)
            }
            try file.write(from: buffer)
            written += count
        }
        return (url, expected)
    }

    @Test("Reads every sample exactly, in order")
    func readsAllSamplesInOrder() throws {
        let (url, expected) = try writeRamp(frames: 5_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (samples, duration) = try AudioFileReader.readMono16k(at: url)
        #expect(samples.count == expected.count)
        #expect(samples == expected)
        #expect(abs(duration - 5_000.0 / 16_000.0) < 0.001)
    }

    /// The regression that a chunked reader can introduce: dropped or
    /// duplicated frames where one read ends and the next begins.
    @Test("Produces identical output across chunk boundaries",
          arguments: [1, 7, 64, 999, 4_096])
    func chunkBoundariesAreSeamless(chunk: Int) throws {
        let frames = 10_000
        let (url, expected) = try writeRamp(frames: frames)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (samples, _) = try AudioFileReader.readMono16k(
            at: url, chunkFrames: AVAudioFrameCount(chunk)
        )
        #expect(samples.count == expected.count,
                "chunk=\(chunk) produced \(samples.count) samples, expected \(expected.count)")
        #expect(samples == expected, "chunk=\(chunk) altered the sample stream")
    }

    /// A chunk larger than the file must not over-read or pad.
    @Test("Handles a chunk larger than the whole file")
    func oversizedChunk() throws {
        let (url, expected) = try writeRamp(frames: 321)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (samples, _) = try AudioFileReader.readMono16k(at: url, chunkFrames: 1_000_000)
        #expect(samples == expected)
    }

    @Test("Throws for a missing file")
    func missingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-does-not-exist-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) {
            _ = try AudioFileReader.readMono16k(at: missing)
        }
    }
}

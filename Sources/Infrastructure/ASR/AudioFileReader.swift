import Foundation
import AVFoundation
import Domain

/// Shared audio-file → [Float] sample reader used by every offline
/// recognizer that has to feed a raw-sample buffer into an MLX model.
///
/// SRP: pure value-extraction helper — no model state, no transcription.
public enum AudioFileReader {

    /// Read the file as 16 kHz mono Float32 samples. Pipeline upstream
    /// (`FFmpegAudioExtractor`) already writes WAVs in this exact format
    /// (`-ar 16000 -ac 1`), so AVAudioFile's processingFormat lands on
    /// Float32 mono and we just copy the channel data out.
    /// Frames read per iteration — 60 s at 16 kHz, ~3.8 MB.
    public static let defaultChunkFrames: AVAudioFrameCount = 16_000 * 60

    /// - Parameter chunkFrames: read granularity. Exposed so tests can drive
    ///   the multi-chunk path without generating minutes of audio.
    public static func readMono16k(
        at url: URL,
        chunkFrames: AVAudioFrameCount = defaultChunkFrames
    ) throws -> (samples: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = file.length
        guard totalFrames > 0 else {
            throw ScribeError.audioFileNotFound(url)
        }

        let duration = Double(totalFrames) / file.processingFormat.sampleRate

        // Read in chunks rather than materialising the whole file as an
        // `AVAudioPCMBuffer` and then copying it into an `Array`. Both used
        // to be alive at once, so a 2-hour video peaked at roughly twice its
        // sample size (~920 MB) before the ASR model was even loaded. Now the
        // destination array is the only full-size allocation, and it is sized
        // up front so appending never reallocates-and-copies.
        guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            throw ScribeError.audioFileNotFound(url)
        }

        var samples = [Float]()
        samples.reserveCapacity(Int(totalFrames))

        while file.framePosition < totalFrames {
            chunk.frameLength = 0
            try file.read(into: chunk, frameCount: chunkFrames)
            let read = Int(chunk.frameLength)
            guard read > 0 else { break }
            guard let channel = chunk.floatChannelData?[0] else {
                throw ScribeError.audioExtractionFailed(
                    underlying: NSError(
                        domain: "AudioFileReader", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio at \(url.lastPathComponent) is not Float32 PCM"]
                    )
                )
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: read))
        }

        return (samples, duration)
    }
}

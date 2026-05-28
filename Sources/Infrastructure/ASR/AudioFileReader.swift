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
    public static func readMono16k(at url: URL) throws -> (samples: [Float], duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else {
            throw ScribeError.audioFileNotFound(url)
        }
        try file.read(into: buffer)

        let duration = Double(file.length) / file.processingFormat.sampleRate

        guard let floatChannels = buffer.floatChannelData else {
            throw ScribeError.audioExtractionFailed(
                underlying: NSError(
                    domain: "AudioFileReader", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Audio at \(url.lastPathComponent) is not Float32 PCM"]
                )
            )
        }
        let samples = Array(UnsafeBufferPointer(start: floatChannels[0], count: Int(buffer.frameLength)))
        return (samples, duration)
    }
}

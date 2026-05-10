import Foundation
import AVFoundation
import Domain

/// Shared audio-file → [Float] sample reader and CJK-ratio language
/// heuristic, used by every offline recognizer that has to feed a
/// raw-sample buffer into an MLX model and pick a language hint for
/// `Qwen3ForcedAligner`.
///
/// SRP: pure value-extraction helpers — no model state, no transcription.
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

    /// Crude CJK-ratio heuristic for picking the aligner's language hint.
    /// `Qwen3ForcedAligner` accepts an open-ended String; "Chinese" steers
    /// its CJK-aware word splitter, "English" uses whitespace tokenisation.
    /// Other scripts fall back to "English" for now.
    public static func detectLanguage(_ text: String) -> String {
        var cjkCount = 0
        var totalNonSpace = 0
        for scalar in text.unicodeScalars {
            if !scalar.properties.isWhitespace {
                totalNonSpace += 1
            }
            if (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) {
                cjkCount += 1
            }
        }
        guard totalNonSpace > 0 else { return "English" }
        return Double(cjkCount) / Double(totalNonSpace) > 0.3 ? "Chinese" : "English"
    }
}

import Foundation
import os
import Domain
import Protocols

/// Inspects audio/video metadata using ffprobe + ffmpeg.
///
/// SRP: Only probes — doesn't modify files.
public final class FFmpegAudioProbe: AudioProbing, @unchecked Sendable {

    private let ffmpegPath: String
    private let logger = Logger(subsystem: "com.scribe", category: "audio.probe")

    public init(ffmpegPath: String? = nil) throws {
        guard let path = ffmpegPath ?? FFmpegLocator.find() else {
            throw ScribeError.ffmpegNotFound
        }
        self.ffmpegPath = path
    }

    // MARK: - AudioProbing

    public func hasAudioStream(in videoURL: URL) async throws -> Bool {
        // Use ffprobe to query stream metadata directly — much more robust
        // than grepping ffmpeg's stderr, which contains noise like
        // `audio:0KiB` in its summary line for video-only files.
        let ffprobePath = ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let cmd = [
            ffprobePath,
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_type",
            "-of", "csv=p=0",
            videoURL.path,
        ]
        do {
            let output = try await FFmpegProcessRunner.runCapturing(cmd, timeout: Constants.audioCheckTimeout)
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "audio"
        } catch {
            logger.warning("Audio check failed, assuming audio exists")
            return true
        }
    }

    public func duration(of audioURL: URL) async throws -> TimeInterval {
        let ffprobePath = ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let cmd = [ffprobePath, "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", audioURL.path]
        do {
            let output = try await FFmpegProcessRunner.runCapturing(cmd, timeout: 30)
            if let d = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
        } catch {
            logger.warning("ffprobe duration failed, estimating from file size")
        }
        // Fallback: estimate from file size
        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL.path)
        let fileSize = attrs[.size] as? Int ?? 0
        return TimeInterval(fileSize) / TimeInterval(Constants.defaultSampleRate * 2)
    }
}

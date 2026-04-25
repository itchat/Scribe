import Foundation
import os
import Domain
import Protocols

/// Extracts audio from video files using FFmpeg.
///
/// SRP: Only handles extraction. Probing metadata lives in `FFmpegAudioProbe`.
public final class FFmpegAudioExtractor: AudioExtracting, @unchecked Sendable {

    private let ffmpegPath: String
    private let useHardwareAccel: Bool
    private let logger = Logger(subsystem: "com.scribe", category: "audio.extractor")
    private let probe: any AudioProbing

    public init(ffmpegPath: String? = nil, probe: (any AudioProbing)? = nil) throws {
        guard let path = ffmpegPath ?? FFmpegLocator.find() else {
            throw ScribeError.ffmpegNotFound
        }
        self.ffmpegPath = path
        self.useHardwareAccel = FFmpegLocator.checkHardwareAcceleration(ffmpegPath: path)
        if let probe {
            self.probe = probe
        } else {
            self.probe = try FFmpegAudioProbe(ffmpegPath: path)
        }
        logger.info("FFmpeg at \(path, privacy: .public), hwaccel: \(self.useHardwareAccel)")
    }

    // MARK: - AudioExtracting

    public func extract(from videoURL: URL, to outputURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            print("[FFmpeg] ERROR: Input file not found: \(videoURL.path)")
            throw ScribeError.audioFileNotFound(videoURL)
        }

        // Reject silent videos up front. The extractor uses `-map a`, which
        // hard-fails when no audio stream exists ("Stream map 'a' matches no
        // streams"). Probing first lets us surface a clear noAudioStream
        // error instead of a wall of ffmpeg stderr.
        guard try await probe.hasAudioStream(in: videoURL) else {
            logger.error("No audio stream in \(videoURL.lastPathComponent, privacy: .public)")
            throw ScribeError.noAudioStream(videoURL)
        }

        print("[FFmpeg] Extracting audio: \(videoURL.lastPathComponent) → \(outputURL.lastPathComponent)")

        let cmd = FFmpegCommandBuilder.audioExtractionCommand(
            ffmpegPath: ffmpegPath,
            inputPath: videoURL.path,
            outputPath: outputURL.path,
            useHardwareAccel: useHardwareAccel
        )

        do {
            try await FFmpegProcessRunner.run(cmd, timeout: Constants.audioExtractionTimeout)
        } catch {
            if useHardwareAccel {
                logger.warning("hwaccel failed, retrying without: \(error.localizedDescription, privacy: .public)")
                let fallbackCmd = FFmpegCommandBuilder.audioExtractionCommand(
                    ffmpegPath: ffmpegPath,
                    inputPath: videoURL.path,
                    outputPath: outputURL.path,
                    useHardwareAccel: false
                )
                try await FFmpegProcessRunner.run(fallbackCmd, timeout: Constants.audioExtractionTimeout)
            } else {
                throw error
            }
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ScribeError.audioExtractionFailed(
                underlying: NSError(domain: "FFmpeg", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Output file missing after extraction"
                ])
            )
        }
        logger.info("Audio extraction completed")
    }
}

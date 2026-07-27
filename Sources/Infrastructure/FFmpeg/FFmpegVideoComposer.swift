import Foundation
import os
import Domain
import Protocols

/// Burns subtitles into video files using FFmpeg subprocess.
///
/// Conforms to `VideoComposing` protocol.
public final class FFmpegVideoComposer: VideoComposing, @unchecked Sendable {

    private let ffmpegPath: String
    private let useHardwareAccel: Bool
    private let logger = Logger(subsystem: "com.scribe", category: "video")

    public init(ffmpegPath: String? = nil) throws {
        guard let path = ffmpegPath ?? FFmpegLocator.find() else {
            throw ScribeError.ffmpegNotFound
        }
        self.ffmpegPath = path
        self.useHardwareAccel = FFmpegLocator.checkHardwareAcceleration(ffmpegPath: path)
    }

    // MARK: - VideoComposing

    public func compose(
        video: URL,
        subtitles: URL,
        output: URL,
        style: SubtitleStyle,
        progress: (any Protocols.ProgressReporting)?
    ) async throws {
        guard FileManager.default.fileExists(atPath: video.path) else {
            throw ScribeError.ffmpegFailed(stderr: "Video file not found: \(video.path)")
        }

        guard FileManager.default.fileExists(atPath: subtitles.path) else {
            throw ScribeError.subtitleFileInvalid(subtitles)
        }

        // Probe the actual video dimensions purely so we can pass
        // `original_size=WxH` to ffmpeg's subtitles filter. libass
        // otherwise scales `FontSize=N` against an implicit PlayResY=288
        // and renders 14pt as ≈90px on a 1920-tall canvas. Falls back to
        // 1280×720 if probing fails.
        let (videoWidth, videoHeight) = getVideoDimensions(video) ?? (1280, 720)
        logger.info("Burning at \(videoWidth, privacy: .public)x\(videoHeight, privacy: .public) with fontSize=\(style.fontSize, privacy: .public), marginV=\(style.marginVertical, privacy: .public), marginL/R=\(style.marginHorizontal, privacy: .public)")

        let cmd = FFmpegCommandBuilder.videoCompositionCommand(
            ffmpegPath: ffmpegPath,
            inputPath: video.path,
            subtitlePath: subtitles.path,
            outputPath: output.path,
            useHardwareAccel: useHardwareAccel,
            style: style,
            videoWidth: videoWidth,
            videoHeight: videoHeight
        )

        let totalDuration = getVideoDuration(video)

        // Run FFmpeg and collect stderr
        let (exitCode, stderrOutput) = runComposition(cmd, totalDuration: totalDuration, progress: progress)

        guard exitCode == 0 else {
            throw ScribeError.ffmpegFailed(stderr: stderrOutput)
        }

        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ScribeError.ffmpegFailed(stderr: "Output file missing")
        }

        progress?.reportProgress(100)
        logger.info("Video composition completed")
    }

    // MARK: - Private

    /// Run FFmpeg synchronously, parsing stderr for progress updates.
    private func runComposition(
        _ cmd: [String],
        totalDuration: TimeInterval?,
        progress: (any Protocols.ProgressReporting)?
    ) -> (exitCode: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: cmd[0])
        process.arguments = Array(cmd.dropFirst())
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch FFmpeg: \(error)")
        }

        var stderrOutput = ""
        let handle = stderrPipe.fileHandleForReading

        // Read stderr line by line for progress
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            if let chunk = String(data: data, encoding: .utf8) {
                stderrOutput += chunk
                // Parse last line for progress
                if let lastLine = chunk.split(separator: "\r").last ?? chunk.split(separator: "\n").last {
                    if let currentTime = FFmpegCommandBuilder.parseProgressTime(from: String(lastLine)),
                       let duration = totalDuration, duration > 0 {
                        let percent = min(99, Int(currentTime / duration * 100))
                        progress?.reportProgress(percent)
                    }
                }
            }
        }

        process.waitUntilExit()
        return (process.terminationStatus, stderrOutput)
    }

    /// Returns the video stream's pixel `(width, height)`, or nil if
    /// probing fails. Used by the subtitle-style resolver to pick a font
    /// size off the shorter dimension — `min(width, height) / 24` — so
    /// portrait clips don't get oversized cues.
    private func getVideoDimensions(_ videoURL: URL) -> (width: Int, height: Int)? {
        let ffprobePath = FFmpegLocator.ffprobePath(forFFmpegAt: ffmpegPath)
        guard FFmpegLocator.exists(at: ffprobePath) else { return nil }

        let process = Process()
        process.executableURL = URL(filePath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0",
            videoURL.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // ffprobe emits e.g. "1920,1080" (CSV with no header).
            let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = str.split(separator: ",")
            guard parts.count == 2,
                  let w = Int(parts[0]),
                  let h = Int(parts[1])
            else { return nil }
            return (w, h)
        } catch {
            return nil
        }
    }

    private func getVideoDuration(_ videoURL: URL) -> TimeInterval? {
        let ffprobePath = FFmpegLocator.ffprobePath(forFFmpegAt: ffmpegPath)
        guard FFmpegLocator.exists(at: ffprobePath) else { return nil }

        let process = Process()
        process.executableURL = URL(filePath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-show_entries", "format=duration",
            "-of", "csv=p=0",
            videoURL.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TimeInterval(str)
        } catch {
            return nil
        }
    }
}

import Foundation
import Domain
import os

/// Locates the FFmpeg binary on the system.
///
/// SRP: Only responsible for finding the ffmpeg path.
public enum FFmpegLocator {

    /// Find the ffmpeg binary, checking bundled locations first, then system paths.
    /// - Returns: Absolute path to ffmpeg, or nil if not found.
    public static func find() -> String? {
        // 1. Check if bundled inside .app (for future distribution)
        if let bundledPath = findBundled() {
            return bundledPath
        }

        // 2. Check well-known system paths
        for path in Constants.ffmpegPaths {
            if exists(at: path) {
                return path
            }
        }

        return nil
    }

    /// Check whether a file exists at the given path.
    public static func exists(at path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// The `ffprobe` binary that sits alongside a given `ffmpeg`.
    ///
    /// Must be a path operation, not a string substitution. The previous
    /// `replacingOccurrences(of: "ffmpeg", with: "ffprobe")` rewrote *every*
    /// occurrence, so Homebrew's `ffmpeg-full` layout — the first candidate
    /// in `Constants.ffmpegPaths`, and therefore the one actually selected
    /// on a typical dev machine — became
    /// `/opt/homebrew/opt/ffprobe-full/bin/ffprobe`, a path that does not
    /// exist. `build-app.sh` already derived it correctly with `dirname`;
    /// this brings the Swift side in line.
    public static func ffprobePath(forFFmpegAt ffmpegPath: String) -> String {
        URL(filePath: ffmpegPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ffprobe")
            .path
    }

    /// Answers already computed, keyed by ffmpeg path.
    private static let hardwareAccelCache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// Check whether VideoToolbox hardware acceleration is supported.
    ///
    /// Cached per binary. Both the extractor and the composer ask in their
    /// initialisers, and both are built for every queued video on the main
    /// actor — so each video used to cost two synchronous `ffmpeg -version`
    /// launches on the UI thread for an answer that cannot change while the
    /// app runs.
    public static func checkHardwareAcceleration(ffmpegPath: String) -> Bool {
        if let cached = hardwareAccelCache.withLock({ $0[ffmpegPath] }) {
            return cached
        }
        let supported = probeHardwareAcceleration(ffmpegPath: ffmpegPath)
        hardwareAccelCache.withLock { $0[ffmpegPath] = supported }
        return supported
    }

    private static func probeHardwareAcceleration(ffmpegPath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: ffmpegPath)
        process.arguments = ["-version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return false }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.lowercased().contains("videotoolbox")
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func findBundled() -> String? {
        // ffmpeg lives next to the main binary in Contents/MacOS/ — the
        // standard slot for helper executables in a macOS .app bundle.
        // For `swift run` dev mode there is no bundled copy, so this
        // returns nil and `find()` falls through to system paths.
        guard let execURL = Bundle.main.executableURL else { return nil }
        let path = execURL.deletingLastPathComponent().appendingPathComponent("ffmpeg").path
        return exists(at: path) ? path : nil
    }
}

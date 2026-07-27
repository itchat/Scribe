import Foundation
import Domain

/// Pure functions for building FFmpeg commands and parsing output.
///
/// SRP: Command construction and output parsing only — no process execution.
/// This separation makes the logic unit-testable without running FFmpeg.
public enum FFmpegCommandBuilder {

    // MARK: - Path Escaping

    /// Characters that must be escaped before a value can be embedded in a
    /// filtergraph. `,` and `;` separate filters, `[` and `]` delimit pad
    /// labels, `:` separates a filter's arguments, `=` separates key from
    /// value, and `'` opens a quoted run.
    private static let filterSpecialCharacters: [String] = ["'", ":", "[", "]", ",", ";", "="]

    /// Escape a value for embedding in an FFmpeg filtergraph argument.
    ///
    /// FFmpeg unescapes filtergraph values through **three** layers (the
    /// graph parser, the filter's argument parser, then `av_get_token`), so
    /// a single backslash is consumed before it ever reaches the filter.
    /// The result must be used **unquoted** — wrapping the output in `'…'`
    /// re-breaks it.
    ///
    /// The previous implementation escaped with a single backslash *and*
    /// wrapped the result in single quotes. That combination silently
    /// dropped apostrophes: a file named `John's talk.srt` reached libass
    /// as `Johns talk.srt`, which does not exist, so the burn failed. It
    /// was also an injection vector, since the apostrophe terminated the
    /// quoted run and let the remainder of the filename be parsed as
    /// filtergraph syntax.
    ///
    /// Escaping levels were established empirically against ffmpeg by
    /// round-tripping each special character through a real `subtitles=`
    /// filter; see `FFmpegCommandBuilderTests`.
    public static func escapeFilterValue(_ value: String) -> String {
        // Backslash first, or we would escape the backslashes we insert.
        var escaped = value.replacingOccurrences(of: "\\", with: #"\\\\"#)
        for character in filterSpecialCharacters {
            escaped = escaped.replacingOccurrences(of: character, with: #"\\\"# + character)
        }
        return escaped
    }

    // MARK: - Audio Extraction

    /// Build the command to extract audio from a video file.
    public static func audioExtractionCommand(
        ffmpegPath: String,
        inputPath: String,
        outputPath: String,
        useHardwareAccel: Bool
    ) -> [String] {
        var cmd = [ffmpegPath, "-nostdin"]

        if useHardwareAccel {
            cmd += ["-hwaccel", "videotoolbox"]
        }

        cmd += [
            "-i", inputPath,
            "-q:a", "0",
            "-map", "a",
            "-ac", String(Constants.defaultAudioChannels),
            "-ar", String(Constants.defaultSampleRate),
            outputPath,
            "-y",
        ]

        return cmd
    }

    /// Build the command to create a silent audio file.
    public static func silentAudioCommand(
        ffmpegPath: String,
        outputPath: String,
        duration: TimeInterval = 0.1
    ) -> [String] {
        [
            ffmpegPath, "-nostdin",
            "-f", "lavfi",
            "-i", "anullsrc=r=\(Constants.defaultSampleRate):cl=mono",
            "-t", String(duration),
            "-q:a", "0",
            outputPath,
            "-y",
        ]
    }

    // MARK: - Video Composition

    /// Build the command to burn subtitles into a video.
    /// `videoWidth`/`videoHeight` are passed to ffmpeg's `subtitles` filter
    /// as `original_size=WxH` — without this, libass falls back to its
    /// internal default PlayResY=288 and scales `FontSize=N` against that,
    /// making FontSize=45 render as ~300px on a 1920-tall canvas
    /// (≈15% of the height — the wall-of-text bug). Telling libass the
    /// real canvas size makes FontSize interpreted in actual pixels.
    public static func videoCompositionCommand(
        ffmpegPath: String,
        inputPath: String,
        subtitlePath: String,
        outputPath: String,
        useHardwareAccel: Bool,
        style: SubtitleStyle,
        videoWidth: Int,
        videoHeight: Int
    ) -> [String] {
        let escapedPath = escapeFilterValue(subtitlePath)
        // libass on macOS uses fontconfig, which by default doesn't index
        // /System/Library/Fonts — so without an explicit `fontsdir`, a
        // request for "New York" falls through to a Verdana-like default.
        // Pointing it at the system font directory makes the FontName=...
        // in our force_style payload actually take effect.
        let fontsDir = escapeFilterValue("/System/Library/Fonts")
        // `force_style` is escaped as a whole. Its internal `=` and `,` are
        // structural *for libass*, but to ffmpeg they are ordinary bytes
        // that must survive the filtergraph parser — escaping them here
        // means libass receives them intact. Values are deliberately not
        // quoted; see `escapeFilterValue`.
        let forceStyle = escapeFilterValue(style.assForceStyle())
        let subtitleFilter =
            "subtitles=\(escapedPath)" +
            ":fontsdir=\(fontsDir)" +
            ":original_size=\(videoWidth)x\(videoHeight)" +
            ":force_style=\(forceStyle)"

        if useHardwareAccel {
            return [
                ffmpegPath, "-nostdin",
                "-hwaccel", "videotoolbox",
                "-i", inputPath,
                "-vf", subtitleFilter,
                "-c:v", "h264_videotoolbox",
                "-q:v", String(Constants.ffmpegQualityParam),
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputPath,
                "-y",
            ]
        } else {
            return [
                ffmpegPath, "-nostdin",
                "-i", inputPath,
                "-vf", subtitleFilter,
                "-c:v", "libx264",
                "-crf", "23",
                "-preset", "medium",
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputPath,
                "-y",
            ]
        }
    }

    // MARK: - Progress Parsing

    /// Parse progress time from an FFmpeg stderr line like `time=00:01:23.45`.
    /// - Returns: Time in seconds, or nil if no time marker found.
    public static func parseProgressTime(from line: String) -> TimeInterval? {
        guard let range = line.range(of: #"time=(\d{2}):(\d{2}):(\d{2})\.(\d{2})"#, options: .regularExpression) else {
            return nil
        }

        let match = String(line[range])
        // match is like "time=00:01:23.45"
        let timeStr = String(match.dropFirst(5)) // drop "time="
        let parts = timeStr.split(separator: ":")
        guard parts.count == 3 else { return nil }

        let secParts = parts[2].split(separator: ".")
        guard secParts.count == 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(secParts[0]),
              let centiseconds = Int(secParts[1])
        else { return nil }

        return TimeInterval(hours * 3600 + minutes * 60 + seconds) + TimeInterval(centiseconds) / 100.0
    }
}

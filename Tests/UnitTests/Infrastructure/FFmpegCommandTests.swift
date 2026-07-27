import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

@Suite("FFmpegLocator")
struct FFmpegLocatorTests {

    @Test("Finds ffmpeg in known system paths")
    func findsFFmpeg() {
        // This test passes on machines with ffmpeg installed via Homebrew
        let path = FFmpegLocator.find()
        if path != nil {
            #expect(path!.hasSuffix("ffmpeg"))
        }
        // Not a failure if ffmpeg is not installed — just skip
    }

    @Test("Checks specific path existence correctly")
    func checksPath() {
        // A path that definitely doesn't exist
        let exists = FFmpegLocator.exists(at: "/nonexistent/ffmpeg")
        #expect(!exists)
    }

    // MARK: - ffprobe derivation

    /// Regression: the old implementation used
    /// `ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")`,
    /// which rewrites *every* occurrence. Homebrew's ffmpeg-full — the
    /// first entry in `Constants.ffmpegPaths`, i.e. the path actually
    /// chosen on a typical dev machine — contains "ffmpeg" twice, so it
    /// produced `/opt/homebrew/opt/ffprobe-full/bin/ffprobe`, which does
    /// not exist. Every ffprobe call then failed and was silently
    /// swallowed: silent-video detection, `original_size` font scaling,
    /// and burn progress all degraded with no user-visible error.
    @Test("Derives ffprobe path when 'ffmpeg' appears twice (Homebrew ffmpeg-full)")
    func ffprobePathForFFmpegFull() {
        let derived = FFmpegLocator.ffprobePath(forFFmpegAt: "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
        #expect(derived == "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")
    }

    @Test("Derives ffprobe path for plain Homebrew and system layouts")
    func ffprobePathForSimpleLayouts() {
        #expect(FFmpegLocator.ffprobePath(forFFmpegAt: "/opt/homebrew/bin/ffmpeg") == "/opt/homebrew/bin/ffprobe")
        #expect(FFmpegLocator.ffprobePath(forFFmpegAt: "/usr/bin/ffmpeg") == "/usr/bin/ffprobe")
    }

    /// A user directory containing "ffmpeg" must not be rewritten either.
    @Test("Derives ffprobe path without touching parent directories")
    func ffprobePathLeavesParentDirsAlone() {
        let derived = FFmpegLocator.ffprobePath(forFFmpegAt: "/Users/me/ffmpeg-builds/ffmpeg")
        #expect(derived == "/Users/me/ffmpeg-builds/ffprobe")
    }
}

@Suite("FFmpegCommandBuilder")
struct FFmpegCommandBuilderTests {

    // MARK: - Path escaping

    // FFmpeg unescapes a filtergraph value through three layers, so each
    // special character needs three backslashes to survive to the filter.
    // These expectations were derived empirically by round-tripping every
    // character through a real `subtitles=` filter and checking which
    // encoding made ffmpeg open the intended file — not from reading the
    // escaping documentation, which is ambiguous about the layering.

    @Test("Escapes colons for the filtergraph argument parser")
    func escapesColons() {
        #expect(FFmpegCommandBuilder.escapeFilterValue("/path/to:file.srt") == #"/path/to\\\:file.srt"#)
    }

    /// The bug that broke real burns: a single backslash plus surrounding
    /// quotes made the apostrophe vanish entirely, so `John's talk.srt`
    /// reached libass as `Johns talk.srt`.
    @Test("Escapes apostrophes so they survive to the filter")
    func escapesSingleQuotes() {
        #expect(FFmpegCommandBuilder.escapeFilterValue("/path/John's.srt") == #"/path/John\\\'s.srt"#)
    }

    @Test("Escapes brackets so they are not read as pad labels")
    func escapesBrackets() {
        #expect(FFmpegCommandBuilder.escapeFilterValue("/path/[to]/f.srt") == #"/path/\\\[to\\\]/f.srt"#)
    }

    @Test("Escapes commas and semicolons so they do not split the filtergraph")
    func escapesFilterSeparators() {
        #expect(FFmpegCommandBuilder.escapeFilterValue("/a,b;c.srt") == #"/a\\\,b\\\;c.srt"#)
    }

    @Test("Escapes backslashes first to avoid double-escaping")
    func escapesBackslashFirst() {
        // The backslash doubles to four; the colon is then escaped once,
        // and its escape is not itself re-escaped.
        #expect(FFmpegCommandBuilder.escapeFilterValue(#"/path\to:file.srt"#) == #"/path\\\\to\\\:file.srt"#)
    }

    @Test("Leaves ordinary paths untouched")
    func leavesPlainPathsAlone() {
        #expect(FFmpegCommandBuilder.escapeFilterValue("/plain/path/file.srt") == "/plain/path/file.srt")
    }

    /// Escaped values must be emitted unquoted — re-wrapping them in `'…'`
    /// reintroduces the apostrophe bug.
    @Test("Subtitle filter emits escaped values without wrapping quotes")
    func subtitleFilterIsUnquoted() {
        let cmd = FFmpegCommandBuilder.videoCompositionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            subtitlePath: "/subs/John's [1080p].srt",
            outputPath: "/output.mp4",
            useHardwareAccel: false,
            style: SubtitleStyle(),
            videoWidth: 1920,
            videoHeight: 1080
        )
        guard let vfIdx = cmd.firstIndex(of: "-vf"), vfIdx < cmd.index(before: cmd.endIndex) else {
            Issue.record("Expected -vf flag in command")
            return
        }
        let filter = cmd[cmd.index(after: vfIdx)]
        #expect(!filter.contains("subtitles='"))
        #expect(!filter.contains("force_style='"))
        #expect(filter.contains(#"John\\\'s"#))
    }

    // MARK: - Audio extraction command

    @Test("Audio extraction command includes correct codec flags")
    func audioExtractionCommand() {
        let cmd = FFmpegCommandBuilder.audioExtractionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            outputPath: "/output.wav",
            useHardwareAccel: false
        )
        #expect(cmd.contains("-map"))
        #expect(cmd.contains("a"))
        #expect(cmd.contains("-ac"))
        #expect(cmd.contains("1"))
        #expect(cmd.contains("-ar"))
        #expect(cmd.contains("16000"))
        #expect(cmd.contains("-y"))
    }

    @Test("Audio extraction command includes VideoToolbox when hardware accel enabled")
    func audioExtractionWithHardwareAccel() {
        let cmd = FFmpegCommandBuilder.audioExtractionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            outputPath: "/output.wav",
            useHardwareAccel: true
        )
        #expect(cmd.contains("-hwaccel"))
        #expect(cmd.contains("videotoolbox"))
    }

    @Test("Audio extraction command omits VideoToolbox when hardware accel disabled")
    func audioExtractionWithoutHardwareAccel() {
        let cmd = FFmpegCommandBuilder.audioExtractionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            outputPath: "/output.wav",
            useHardwareAccel: false
        )
        #expect(!cmd.contains("videotoolbox"))
    }

    // MARK: - Video composition command

    @Test("Video composition command with hardware acceleration uses h264_videotoolbox")
    func compositionWithHardwareAccel() {
        let cmd = FFmpegCommandBuilder.videoCompositionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            subtitlePath: "/subs.srt",
            outputPath: "/output.mp4",
            useHardwareAccel: true,
            style: SubtitleStyle(),
            videoWidth: 1920,
            videoHeight: 1080
        )
        #expect(cmd.contains("h264_videotoolbox"))
        #expect(cmd.contains("-hwaccel"))
    }

    @Test("Video composition command without hardware acceleration uses libx264")
    func compositionWithoutHardwareAccel() {
        let cmd = FFmpegCommandBuilder.videoCompositionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            subtitlePath: "/subs.srt",
            outputPath: "/output.mp4",
            useHardwareAccel: false,
            style: SubtitleStyle(),
            videoWidth: 1920,
            videoHeight: 1080
        )
        #expect(cmd.contains("libx264"))
        #expect(!cmd.contains("videotoolbox"))
    }

    @Test("Video composition command includes subtitle filter with font size")
    func compositionSubtitleFilter() {
        let cmd = FFmpegCommandBuilder.videoCompositionCommand(
            ffmpegPath: "/usr/local/bin/ffmpeg",
            inputPath: "/input.mp4",
            subtitlePath: "/subs.srt",
            outputPath: "/output.mp4",
            useHardwareAccel: false,
            style: SubtitleStyle(),
            videoWidth: 1920,
            videoHeight: 1080
        )
        // Find the -vf argument
        if let vfIdx = cmd.firstIndex(of: "-vf"), vfIdx < cmd.index(before: cmd.endIndex) {
            let filter = cmd[cmd.index(after: vfIdx)]
            #expect(filter.contains("subtitles="))
            // `force_style`'s internal `=` and `,` are escaped so the
            // filtergraph parser passes them through to libass intact —
            // hence the escaped forms here rather than bare `FontSize=`.
            #expect(filter.contains(#"FontSize\\\="#))
            // libass on macOS won't find /System/Library/Fonts on its own
            // — we must point fontsdir there or the FontName is ignored.
            #expect(filter.contains("fontsdir="))
            #expect(filter.contains("System/Library/Fonts"))
            // The bundled-serif font name must be threaded through.
            #expect(filter.contains(#"FontName\\\=New York"#))
            // Without original_size, libass scales FontSize against an
            // implicit PlayResY=288 → 45pt FontSize renders 300px tall
            // on a 1920-tall video. Passing original_size pins PlayRes
            // to the real canvas so FontSize is in pixels.
            #expect(filter.contains("original_size=1920x1080"))
        } else {
            Issue.record("Expected -vf flag in command")
        }
    }

    // MARK: - Progress parsing

    @Test("Parses time from FFmpeg stderr line")
    func parseTime() {
        let line = "frame=  100 fps=25.0 q=28.0 size=    1024kB time=00:01:23.45 bitrate= 100.0kbits/s"
        let time = FFmpegCommandBuilder.parseProgressTime(from: line)
        #expect(time != nil)
        #expect(abs(time! - 83.45) < 0.01)
    }

    @Test("Returns nil for line without time marker")
    func parseTimeNoMarker() {
        let line = "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'video.mp4':"
        let time = FFmpegCommandBuilder.parseProgressTime(from: line)
        #expect(time == nil)
    }

    @Test("Parses zero time correctly")
    func parseZeroTime() {
        let line = "time=00:00:00.00"
        let time = FFmpegCommandBuilder.parseProgressTime(from: line)
        #expect(time != nil)
        #expect(time! == 0.0)
    }
}

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
}

@Suite("FFmpegCommandBuilder")
struct FFmpegCommandBuilderTests {

    // MARK: - Path escaping

    @Test("Escapes colons in subtitle path")
    func escapesColons() {
        let escaped = FFmpegCommandBuilder.escapeSubtitlePath("/path/to:file.srt")
        #expect(escaped.contains("\\:"))
    }

    @Test("Escapes single quotes in subtitle path")
    func escapesSingleQuotes() {
        let escaped = FFmpegCommandBuilder.escapeSubtitlePath("/path/to'file.srt")
        #expect(escaped.contains("\\'"))
    }

    @Test("Escapes brackets in subtitle path")
    func escapesBrackets() {
        let escaped = FFmpegCommandBuilder.escapeSubtitlePath("/path/[to]/file.srt")
        #expect(escaped.contains("\\["))
        #expect(escaped.contains("\\]"))
    }

    @Test("Escapes backslashes first to avoid double-escaping")
    func escapesBackslashFirst() {
        let escaped = FFmpegCommandBuilder.escapeSubtitlePath("/path\\to:file.srt")
        // Backslash should be escaped before colon
        #expect(escaped == "/path\\\\to\\:file.srt")
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
            useHardwareAccel: true
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
            useHardwareAccel: false
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
            useHardwareAccel: false
        )
        // Find the -vf argument
        if let vfIdx = cmd.firstIndex(of: "-vf"), vfIdx < cmd.index(before: cmd.endIndex) {
            let filter = cmd[cmd.index(after: vfIdx)]
            #expect(filter.contains("subtitles="))
            #expect(filter.contains("FontSize="))
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

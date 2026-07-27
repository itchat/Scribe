import Foundation
import os
import Domain

/// Shared FFmpeg subprocess runner.
///
/// Centralizes pipe/stderr/timeout handling for both extractor and probe.
/// SRP: Only runs external processes, doesn't know about audio or video semantics.
enum FFmpegProcessRunner {

    private static let logger = Logger(subsystem: "com.scribe", category: "ffmpeg.runner")

    /// Run FFmpeg and throw on non-zero exit. Enforces timeout and captures stderr.
    static func run(_ arguments: [String], timeout: TimeInterval) async throws {
        // The argv contains every input and output path. Video filenames are
        // unusually revealing — employer, client, medical or legal context —
        // and the unified log is persisted and collected in sysdiagnose. Log
        // the shape publicly and the contents privately, so a bug report is
        // still diagnosable on the user's own machine without publishing
        // their filenames to anyone who runs `log show`.
        logger.info(
            "CMD: \(arguments.count, privacy: .public) args: \(arguments.joined(separator: " "), privacy: .private)"
        )

        let (exitCode, stderr) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Int32, String), any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice

                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                    print("[FFmpeg] Process launched (PID: \(process.processIdentifier))")
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning {
                        print("[FFmpeg] TIMEOUT after \(timeout)s — killing process")
                        process.terminate()
                    }
                }
                timer.resume()

                var stderrData = Data()
                let readQueue = DispatchQueue(label: "ffmpeg.stderr")
                readQueue.async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                }

                process.waitUntilExit()
                timer.cancel()
                readQueue.sync {}

                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let exit = process.terminationStatus
                print("[FFmpeg] Exited with code: \(exit)")
                if !stderr.isEmpty {
                    for line in stderr.components(separatedBy: "\n").suffix(5) where !line.isEmpty {
                        print("[FFmpeg] stderr: \(line)")
                    }
                }
                continuation.resume(returning: (exit, stderr))
            }
        }

        if exitCode != 0 {
            let msg = String(stderr.suffix(500))
            // ffmpeg's stderr echoes the input and output paths back, so it
            // carries the same filename exposure as the argv above.
            logger.error("failed (\(exitCode, privacy: .public)): \(msg, privacy: .private)")
            throw ScribeError.audioExtractionFailed(
                underlying: NSError(domain: "FFmpeg", code: Int(exitCode), userInfo: [
                    NSLocalizedDescriptionKey: msg.isEmpty ? "FFmpeg exit code \(exitCode)" : msg
                ])
            )
        }
        print("[FFmpeg] Success")
    }

    /// Run a command and return combined stdout+stderr output.
    static func runCapturing(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: arguments[0])
                process.arguments = Array(arguments.dropFirst())
                process.standardInput = FileHandle.nullDevice

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning { process.terminate() }
                }
                timer.resume()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: stdout + stderr)
            }
        }
    }
}

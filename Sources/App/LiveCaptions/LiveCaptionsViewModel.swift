import SwiftUI
import AppKit
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import Foundation
import os
import Domain
import Protocols
import Core
import Infrastructure

/// Drives the Live Captions window: starts capture + Nemotron streaming ASR
/// and surfaces the rolling caption text and history to the view.
///
/// SRP: orchestrates UI state. Audio capture lives in `SystemAudioCapture`;
/// ASR lives in `NemotronStreamingRecognizer`. This class owns neither
/// concrete type — depends on the protocols (DIP).
@Observable
@MainActor
final class LiveCaptionsViewModel {

    // MARK: - Surface state

    enum LifecycleState: Sendable, Equatable {
        case idle
        case loadingModel
        case capturing
        case stopping
        case failed(String)
    }

    var state: LifecycleState = .idle
    /// Currently selected engine. Persisted to `AppConfig.liveCaptionEngine`
    /// when changed, so the next launch reopens with the same choice.
    var engine: LiveCaptionEngine
    /// The most recent partial transcript, displayed prominently.
    var currentCaption: String = ""
    /// Finalized caption lines with the wall-clock time they were emitted.
    /// Displayed as smaller history above the live line, exported as SRT/text.
    var history: [LiveCaptionEntry] = []
    /// When the current Live Captions session began. Used as the SRT t=0
    /// reference. Reset to `nil` when the user clears history.
    var sessionStartedAt: Date?

    /// Whether there's anything to copy / clear / export.
    var hasContent: Bool {
        !history.isEmpty || !currentCaption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let logger = Logger(subsystem: "com.scribe", category: "live-captions.vm")

    // MARK: - Dependencies (DIP)

    private let source: any LiveAudioSource
    private var recognizer: any StreamingTranscribing
    private let configService: ConfigService
    private var partialsTask: Task<Void, Never>?

    init(
        source: any LiveAudioSource = SystemAudioCapture(),
        configService: ConfigService = ConfigService()
    ) {
        // Persisted engine choice survives across app launches.
        configService.load()
        let initialEngine = configService.config.liveCaptionEngine
        self.source = source
        self.engine = initialEngine
        self.configService = configService
        self.recognizer = Self.makeRecognizer(for: initialEngine)
    }

    // MARK: - Public actions

    func start() {
        guard case .idle = state else { return }
        Task { await startInternal() }
    }

    func stop() {
        switch state {
        case .capturing, .loadingModel: break
        default: return
        }
        state = .stopping
        Task { await stopInternal() }
    }

    /// Switch engines. Stops any running session, swaps the recognizer, and
    /// persists the choice. The user must press Start again to begin.
    func setEngine(_ newEngine: LiveCaptionEngine) {
        guard newEngine != engine else { return }
        engine = newEngine

        // Persist immediately so the next launch reopens with this engine.
        var cfg = configService.config
        cfg.liveCaptionEngine = newEngine
        configService.update(cfg)

        Task {
            if case .capturing = state { await stopInternal() }
            recognizer = Self.makeRecognizer(for: newEngine)
        }
    }

    func openScreenRecordingSettings() {
        SystemAudioPermission.openSettings()
    }

    // MARK: - Export / clipboard / clear

    /// Copy the entire transcript (history + the in-progress line) to the
    /// system pasteboard.
    func copyTranscriptToClipboard() {
        let text = LiveCaptionExporter.clipboardString(entries: history, current: currentCaption)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Clear all captions (history + the in-progress line) and reset the
    /// session start time. Does not stop a running capture session — the
    /// next caption will start a fresh history.
    func clearTranscript() {
        history.removeAll()
        currentCaption = ""
        sessionStartedAt = nil
    }

    /// Show a Save panel to write the transcript to disk as SRT.
    func exportSRT() {
        let start = sessionStartedAt ?? history.first?.emittedAt ?? Date()
        let body = LiveCaptionExporter.srt(entries: history, sessionStart: start)
        runSavePanel(
            defaultName: "scribe-live-captions.srt",
            allowedTypes: [Self.srtUType, .plainText],
            body: body
        )
    }

    /// Show a Save panel to write the transcript to disk as plain text.
    func exportPlainText() {
        let body = LiveCaptionExporter.plainText(entries: history)
        runSavePanel(
            defaultName: "scribe-live-captions.txt",
            allowedTypes: [.plainText],
            body: body
        )
    }

    private static let srtUType: UTType = UTType(filenameExtension: "srt") ?? .plainText

    private func runSavePanel(defaultName: String, allowedTypes: [UTType], body: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = allowedTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write transcript: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Quit Scribe so the user can relaunch and pick up newly-granted TCC
    /// permissions. macOS doesn't refresh permissions for already-running
    /// processes — Apple's documented guidance is "quit and reopen the app."
    func quitToReapplyPermissions() {
        NSApp.terminate(nil)
    }

    // MARK: - Internal flow

    private func startInternal() async {
        state = .loadingModel
        // Stamp the start of this capture session so future SRT exports have
        // a t=0 reference. Don't overwrite if the user is "resuming" after a
        // stop without clearing — keep the original session start so the SRT
        // timeline stays continuous.
        if sessionStartedAt == nil { sessionStartedAt = Date() }
        do {
            try await recognizer.start()
        } catch {
            logger.error("Nemotron load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("ASR engine failed: \(error.localizedDescription)")
            return
        }

        // Subscribe to partials before starting capture so we can't miss a frame.
        let stream = await recognizer.partials
        partialsTask = Task { [weak self] in
            for await update in stream {
                guard let self else { break }
                await self.applyUpdate(update)
            }
        }

        // Start the audio source. We do NOT preflight Screen Recording
        // permission via CGPreflightScreenCaptureAccess — the running process
        // may have a stale view of the TCC database. Instead let SCStream tell
        // us the truth on `startCapture()` and translate any failure into a
        // user-actionable error.
        let recognizer = self.recognizer
        do {
            try await source.start { buffer in
                Task.detached(priority: .userInitiated) {
                    try? await recognizer.appendAudio(buffer)
                }
            }
        } catch {
            logger.error("SCStream startCapture failed: \(error.localizedDescription, privacy: .public)")
            partialsTask?.cancel()
            partialsTask = nil
            try? await self.recognizer.reset()
            state = .failed(Self.captureErrorMessage(from: error))
            return
        }

        state = .capturing
    }

    private func stopInternal() async {
        await source.stop()

        if let final = try? await recognizer.finish() {
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, history.last?.text != trimmed {
                history.append(LiveCaptionEntry(text: trimmed, emittedAt: Date()))
            }
        }
        partialsTask?.cancel()
        partialsTask = nil
        currentCaption = ""
        state = .idle
    }

    private func applyUpdate(_ update: LiveCaptionUpdate) {
        if update.isFinal {
            let final = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty, history.last?.text != final {
                history.append(LiveCaptionEntry(text: final, emittedAt: update.timestamp))
            }
            currentCaption = ""
        } else {
            currentCaption = update.text
        }
    }

    /// Build the recognizer for a chosen engine. Adding a future engine is
    /// just adding a `case` here + a new `StreamingTranscribing` conformer.
    private static func makeRecognizer(for engine: LiveCaptionEngine) -> any StreamingTranscribing {
        switch engine {
        case .nemotron:             return NemotronStreamingRecognizer()
        case .zipformerZhXLarge:    return SherpaZipformerXLargeStreamingRecognizer()
        case .paraformerTrilingual: return SherpaParaformerTrilingualStreamingRecognizer()
        case .qwen3ASRSmall:        return Qwen3ASRStreamingRecognizer(size: .b0_6)
        case .qwen3ASRLarge:        return Qwen3ASRStreamingRecognizer(size: .b1_7)
        }
    }

    /// Translate raw `SCStream`/permission errors into something a user can act on.
    private static func captureErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        let lower = nsError.localizedDescription.lowercased()
        let isPermissionError =
            nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
            || lower.contains("declined")
            || lower.contains("permission")
            || lower.contains("denied")
            || lower.contains("not authorized")
            || nsError.code == -3801   // SCStreamErrorUserDeclined

        if isPermissionError {
            return """
            Screen Recording permission was not granted to this build of Scribe.

            macOS only applies new permissions after the app restarts. If you just toggled Scribe on in System Settings → Screen & System Audio Recording, click Quit Scribe below and reopen the app.
            """
        }
        return "Failed to start system audio capture: \(nsError.localizedDescription)"
    }
}

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

    /// Consumes the recognizer's partials. `nonisolated(unsafe)` so `deinit`
    /// — which runs outside the main actor — can cancel it. Safe because
    /// `deinit` only runs once no other reference exists, so there is no
    /// concurrent access, and `Task.cancel()` is itself thread-safe.
    private nonisolated(unsafe) var partialsTask: Task<Void, Never>?

    /// Single serial consumer of captured audio. See `startInternal`.
    private nonisolated(unsafe) var audioTask: Task<Void, Never>?

    /// Feeds `audioTask`. Finished on stop so the consumer loop exits.
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Upper bound on buffered-but-unprocessed audio chunks.
    ///
    /// ScreenCaptureKit delivers roughly 25–50 buffers/second, so this is
    /// about 3–5 seconds of slack. When ASR cannot keep up — the normal case
    /// for a large model on an 8 GB machine — the oldest chunks are dropped
    /// instead of queueing without bound. Losing audio degrades the
    /// transcript; queueing it without bound degrades the whole machine.
    private static let maxBufferedAudioChunks = 128

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
            // Tear down for every state that can own a live engine, not just
            // `.capturing`. `.failed` is reachable *after* `recognizer.start()`
            // succeeded (the SCStream error path), and the engine picker stays
            // enabled there — so switching engines from a failed session used
            // to drop a fully-loaded recognizer on the floor without stopping
            // it, pinning its weights for the life of the process. One leaked
            // model per switch.
            switch state {
            case .capturing, .loadingModel, .stopping:
                await stopInternal()
            case .failed:
                teardownSession()
                _ = try? await recognizer.finish()
                state = .idle
            case .idle:
                break
            }
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
    ///
    /// Also resets the engine's own session state. Clearing only the view
    /// model used to be cosmetic: the recognizer still held the utterance in
    /// progress, so the next partial re-populated the line the user had just
    /// cleared.
    func clearTranscript() {
        history.removeAll()
        currentCaption = ""
        sessionStartedAt = nil
        let recognizer = self.recognizer
        Task { try? await recognizer.reset() }
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
                self.applyUpdate(update)
            }
        }

        // Start the audio source. We do NOT preflight Screen Recording
        // permission via CGPreflightScreenCaptureAccess — the running process
        // may have a stale view of the TCC database. Instead let SCStream tell
        // us the truth on `startCapture()` and translate any failure into a
        // user-actionable error.
        // One long-lived consumer, not a task per buffer.
        //
        // Spawning `Task.detached` per incoming buffer meant N unordered
        // tasks racing into `appendAudio`, which resamples through a single
        // stateful `AudioConverter` before hopping to the recognizer actor —
        // an actual data race, and one that also scrambled sample order
        // whenever more than one task was in flight. Worse, while the actor
        // sat inside a multi-second decode every new buffer spawned another
        // task holding another 48 kHz `AVAudioPCMBuffer` alive.
        //
        // A bounded stream with a single consumer restores ordering, removes
        // the race, and converts overload from unbounded memory growth into
        // bounded audio loss.
        let (audioStream, audioCont) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBufferedAudioChunks)
        )
        audioContinuation = audioCont

        let recognizer = self.recognizer
        audioTask = Task.detached(priority: .userInitiated) {
            for await buffer in audioStream {
                if Task.isCancelled { break }
                try? await recognizer.appendAudio(buffer)
            }
        }

        do {
            try await source.start { buffer in
                audioCont.yield(buffer)
            }
        } catch {
            logger.error("SCStream startCapture failed: \(error.localizedDescription, privacy: .public)")
            teardownSession()
            // `reset()` rather than `finish()`: the engine stays loaded so a
            // retry doesn't re-download, but the session state is cleared.
            try? await self.recognizer.reset()
            state = .failed(Self.captureErrorMessage(from: error))
            return
        }

        state = .capturing
    }

    /// Cancel the consumer tasks and close the audio stream. Safe to call
    /// more than once and from any lifecycle state.
    private func teardownSession() {
        audioContinuation?.finish()
        audioContinuation = nil
        audioTask?.cancel()
        audioTask = nil
        partialsTask?.cancel()
        partialsTask = nil
    }

    private func stopInternal() async {
        await source.stop()
        // Close the audio path before finishing the recognizer so no buffer
        // arrives after `finish()` has torn down its continuation.
        teardownSession()

        if let final = try? await recognizer.finish() {
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, history.last?.text != trimmed {
                history.append(LiveCaptionEntry(text: trimmed, emittedAt: Date()))
            }
        }
        currentCaption = ""
        state = .idle
    }

    /// Last-resort cleanup for the case where the window is closed without
    /// the view's `.onDisappear` running (or before it does).
    ///
    /// Without this, closing the Live Captions window left the SCStream
    /// capturing system audio indefinitely and pinned the loaded model for
    /// the life of the process — the capture indicator stayed lit with no
    /// window on screen.
    deinit {
        partialsTask?.cancel()
        audioTask?.cancel()
    }

    private func applyUpdate(_ update: LiveCaptionUpdate) {
        if update.isFinal {
            let final = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty, history.last?.text != final {
                history.append(LiveCaptionEntry(text: final, emittedAt: update.timestamp))
                trimHistoryIfNeeded()
            }
            currentCaption = ""
        } else {
            currentCaption = update.text
        }
    }

    /// Hard ceiling on retained caption lines.
    ///
    /// Now that engines commit per utterance, `history` grows for the whole
    /// session instead of holding a single entry. At conversational pace this
    /// is a few thousand lines an hour, so an all-day session needs a bound.
    /// 5000 lines is roughly 8–12 hours of speech and a few hundred KB.
    private static let maxHistoryEntries = 5000

    private func trimHistoryIfNeeded() {
        guard history.count > Self.maxHistoryEntries else { return }
        let overflow = history.count - Self.maxHistoryEntries
        history.removeFirst(overflow)
        logger.info("Trimmed \(overflow, privacy: .public) caption line(s) past the history cap")
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

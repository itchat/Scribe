@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FluidAudio
import Domain
import Protocols

/// Streaming ASR engine wrapping FluidAudio's `StreamingNemotronAsrManager`
/// (Nemotron 0.6B, 1120 ms chunks — best-quality English streaming variant).
///
/// SRP: only owns the streaming model lifecycle and translates its callback
/// into our `LiveCaptionUpdate` AsyncStream.
/// DIP: callers see only `StreamingTranscribing`, not FluidAudio internals.
public actor NemotronStreamingRecognizer: StreamingTranscribing {

    private let logger = Logger(subsystem: "com.scribe", category: "asr.nemotron.streaming")
    private let manager: any StreamingAsrManager
    private var loaded = false

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    /// Background task that drains the engine's internal buffer at the chunk
    /// boundary. Started in `start()`, cancelled on `finish()`/`reset()`.
    private var processingTask: Task<Void, Never>?

    public init(variant: StreamingModelVariant = .nemotron1120ms) {
        self.manager = variant.createManager()
    }

    public var partials: AsyncStream<LiveCaptionUpdate> {
        get async {
            if let stream { return stream }
            let (newStream, newCont) = AsyncStream<LiveCaptionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.stream = newStream
            self.continuation = newCont
            return newStream
        }
    }

    public func start() async throws {
        if loaded { return }

        try await manager.loadModels()

        // Wire FluidAudio's partial callback into our AsyncStream.
        let cont = await ensureContinuation()
        await manager.setPartialTranscriptCallback { text in
            cont.yield(LiveCaptionUpdate(text: text))
        }

        startDrainLoop()

        loaded = true
        let name = await manager.displayName
        logger.info("Nemotron streaming engine ready (\(name, privacy: .public))")
    }

    public nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        // `nonisolated` so the buffer doesn't have to cross our actor's
        // executor on the way to FluidAudio's actor — that hop tripped Swift 6
        // strict-concurrency Sendable checks even with `@preconcurrency import
        // AVFoundation`. `manager` is a `let`, so reading it from a nonisolated
        // method is safe.
        try await manager.appendAudio(buffer)
    }

    public func finish() async throws -> String {
        processingTask?.cancel()
        processingTask = nil

        let final = try await manager.finish()
        let cont = await ensureContinuation()
        cont.yield(LiveCaptionUpdate(text: final, isFinal: true))
        cont.finish()

        // Detach the callback before dropping our continuation. FluidAudio
        // holds the escaping closure, and the closure captured the
        // continuation strongly — so nilling `continuation` alone left the
        // old one alive inside the manager, and a start → finish → start
        // cycle stacked a second closure over a second continuation while
        // the first was still retained. The API takes a non-optional
        // closure, so a no-op capturing nothing is how it gets cleared.
        await manager.setPartialTranscriptCallback { _ in }

        self.continuation = nil
        self.stream = nil
        loaded = false
        return final
    }

    public func reset() async throws {
        processingTask?.cancel()
        processingTask = nil
        try await manager.reset()
        // Restart the drain loop so the next session is immediately live.
        startDrainLoop()
    }

    // MARK: - Private

    /// Drain the engine's chunk queue every ~200 ms. Nemotron's API needs an
    /// explicit `processBufferedAudio()` to advance through complete chunks;
    /// a steady cadence keeps latency consistent.
    ///
    /// Captures `self` weakly and **stops** when it goes away. The previous
    /// version captured the FluidAudio manager strongly in a detached task
    /// that was cancelled only from `finish()`/`reset()`. Any other way of
    /// dropping the recognizer — closing the window, switching engines from
    /// a failed state — left the task running forever, pinning the CoreML
    /// weights for the life of the process and waking the CPU 5×/second with
    /// nothing listening.
    private func startDrainLoop() {
        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.drainOnce()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func drainOnce() async {
        try? await manager.processBufferedAudio()
    }

    private func ensureContinuation() async -> AsyncStream<LiveCaptionUpdate>.Continuation {
        if let continuation { return continuation }
        _ = await partials  // forces creation
        return continuation!
    }
}

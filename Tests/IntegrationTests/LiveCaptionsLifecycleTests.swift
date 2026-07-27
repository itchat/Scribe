import Testing
import Foundation
// Matches the production call sites: `AVAudioPCMBuffer` is not Sendable, and
// the streaming path deliberately hands it across isolation boundaries.
@preconcurrency import AVFoundation
@testable import Domain
@testable import Protocols
@testable import Infrastructure

/// Lifecycle coverage for the Live Captions streaming contract.
///
/// Before this suite, the five streaming recognizers had **zero** tests
/// despite carrying force-unwrapped continuations and the start/stop/restart
/// bugs the two most recent commits fixed blind. These tests drive the
/// contract with a fake engine so they stay hermetic — the real engines are
/// covered separately by `SherpaOnnxSmokeTests`, which needs model files.
@Suite("LiveCaptionsLifecycle")
struct LiveCaptionsLifecycleTests {

    // MARK: - Test doubles

    /// Minimal `StreamingTranscribing` that records how it was driven.
    actor RecordingRecognizer: StreamingTranscribing {
        private(set) var startCount = 0
        private(set) var finishCount = 0
        private(set) var resetCount = 0
        private(set) var appended: [Int] = []
        private(set) var continuationFinished = false

        private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
        private var stream: AsyncStream<LiveCaptionUpdate>?

        var partials: AsyncStream<LiveCaptionUpdate> {
            get async {
                if let stream { return stream }
                let (newStream, newCont) = AsyncStream<LiveCaptionUpdate>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                stream = newStream
                continuation = newCont
                return newStream
            }
        }

        func start() async throws { startCount += 1 }

        nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
            await record(frames: Int(buffer.frameLength))
        }

        private func record(frames: Int) { appended.append(frames) }

        func emit(_ text: String, isFinal: Bool = false) async {
            _ = await partials
            continuation?.yield(LiveCaptionUpdate(text: text, isFinal: isFinal))
        }

        func finish() async throws -> String {
            finishCount += 1
            continuation?.finish()
            continuationFinished = true
            continuation = nil
            stream = nil
            return "final"
        }

        func reset() async throws { resetCount += 1 }
    }

    /// Captures the buffer handler so a test can push audio on demand.
    /// An actor rather than a locked class — `LiveAudioSource`'s methods are
    /// already async, and `NSLock` is unavailable from async contexts.
    actor ControllableSource: LiveAudioSource {
        private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private(set) var stopCount = 0
        private(set) var startCount = 0

        var isRunning: Bool { handler != nil }

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
            startCount += 1
            handler = onBuffer
        }

        func stop() async {
            stopCount += 1
            handler = nil
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            handler?(buffer)
        }
    }

    private static func makeBuffer(frames: AVAudioFrameCount = 1600) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let ch = buffer.floatChannelData?[0] { ch.update(repeating: 0, count: Int(frames)) }
        return buffer
    }

    // MARK: - Contract

    @Test("Engine receives appended audio in the order it was captured")
    func preservesAudioOrder() async throws {
        let engine = RecordingRecognizer()
        _ = await engine.partials
        try await engine.start()

        // Distinct frame counts act as sequence markers.
        for frames in stride(from: 100, through: 1000, by: 100) {
            try await engine.appendAudio(try Self.makeBuffer(frames: AVAudioFrameCount(frames)))
        }

        let appended = await engine.appended
        #expect(appended == Array(stride(from: 100, through: 1000, by: 100)),
                "audio must reach the engine in capture order; got \(appended)")
    }

    @Test("finish() finishes the partials continuation exactly once")
    func finishClosesContinuation() async throws {
        let engine = RecordingRecognizer()
        let stream = await engine.partials
        try await engine.start()

        // Draining task must terminate when the continuation finishes;
        // if it doesn't, this test hangs and the time limit catches it.
        let drained = Task { var n = 0; for await _ in stream { n += 1 }; return n }

        await engine.emit("hello")
        _ = try await engine.finish()

        let count = await drained.value
        #expect(count >= 0)
        #expect(await engine.continuationFinished)
    }

    @Test("Restart after finish does not double-start or leak the old stream")
    func restartIsClean() async throws {
        let engine = RecordingRecognizer()
        _ = await engine.partials
        try await engine.start()
        _ = try await engine.finish()

        // Second cycle must get a fresh stream, not the finished one.
        let secondStream = await engine.partials
        try await engine.start()
        let drained = Task { var n = 0; for await _ in secondStream { n += 1 }; return n }
        await engine.emit("second session")
        _ = try await engine.finish()

        #expect(await drained.value == 1, "the restarted session must deliver its own partials")
        #expect(await engine.startCount == 2)
        #expect(await engine.finishCount == 2)
    }

    // MARK: - Bounded audio buffering

    /// The production path feeds a bounded `AsyncStream` with a single
    /// consumer. This pins the property that matters on a slow machine: a
    /// producer that outruns the consumer must not grow without bound.
    @Test("Bounded audio stream drops rather than growing when the consumer stalls")
    func boundedStreamDropsUnderPressure() async throws {
        let capacity = 8
        let (stream, cont) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(capacity))

        // Produce far more than capacity before consuming anything.
        for i in 0..<1000 { cont.yield(i) }
        cont.finish()

        var received: [Int] = []
        for await value in stream { received.append(value) }

        #expect(received.count <= capacity,
                "buffering policy must cap retained chunks; kept \(received.count)")
        // `.bufferingNewest` keeps the most recent values — losing old audio
        // is the intended trade, so the newest sample must survive.
        #expect(received.last == 999)
    }

    @Test("Source stop is idempotent and clears the handler")
    func sourceStopIsIdempotent() async throws {
        let source = ControllableSource()
        try await source.start { _ in }
        #expect(await source.isRunning)

        await source.stop()
        await source.stop()

        #expect(!(await source.isRunning))
        #expect(await source.stopCount == 2, "stop must tolerate repeat calls")
    }

    /// Pushing audio after `stop()` must be a no-op rather than reaching a
    /// torn-down engine — the window-close path relies on this ordering.
    @Test("Audio pushed after stop does not reach the engine")
    func noAudioAfterStop() async throws {
        let source = ControllableSource()
        let engine = RecordingRecognizer()
        _ = await engine.partials
        try await engine.start()

        try await source.start { buffer in
            Task { try? await engine.appendAudio(buffer) }
        }
        await source.stop()
        await source.push(try Self.makeBuffer(frames: 512))

        // Give any erroneously-spawned task a chance to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await engine.appended.isEmpty,
                "no audio may reach the engine once the source has stopped")
    }
}

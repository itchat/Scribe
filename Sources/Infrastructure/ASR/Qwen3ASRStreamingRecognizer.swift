@preconcurrency import AVFoundation
import Foundation
import os
@preconcurrency import FluidAudio
import MLX
import Domain
import Protocols
import Qwen3ASR
import SpeechVAD

/// Live-Captions streaming engine backed by Qwen3-ASR (MLX 4-bit) +
/// Silero VAD. Used when the user picks a Qwen3 variant in the engine
/// picker.
///
/// Why VAD-segmented instead of a continuous prompt-prefix-rollback
/// algorithm (the one in `qwen_asr.py:streaming_transcribe`):
/// `speech-swift`'s `Qwen3ASRModel.transcribe` does not expose the
/// streaming prefix-prompt knobs, so we cannot 1:1 port the official
/// stable-prefix algorithm. Instead we mirror `speech-swift`'s own
/// `StreamingASR` but adapt it from a pull-style API (consumes a
/// complete `[Float]` buffer) to a push-style API driven by the
/// AVAudioPCMBuffer callbacks our `SystemAudioCapture` emits.
///
/// Algorithm summary:
///   1. Every appended buffer is resampled to 16 kHz mono and pushed
///      into an in-memory float buffer.
///   2. A background task drains the buffer in 512-sample chunks
///      through `StreamingVADProcessor`.
///   3. On `speechStarted` we mark the absolute sample index so we
///      know where to slice the segment from.
///   4. While speech is in progress, every ~1 s we slice
///      `samples[speechStart…cursor]` and ask Qwen3-ASR for a partial
///      with `maxTokens=32` — emitted as a non-final update.
///   5. On `speechEnded` we transcribe the final slice and emit a
///      final update, append the text to `committed`, and compact the
///      buffer so we don't grow without bound for long sessions.
///   6. `finish()` flushes the VAD and emits one last update so
///      anything still in flight survives into the SRT export.
///
/// Emitted `LiveCaptionUpdate.text` is cumulative (per the protocol
/// contract): `committed + " " + currentLive`.
///
/// SRP: only the ASR lifecycle + VAD bridging live here. Audio capture
/// stays in `SystemAudioCapture`; resampling stays in FluidAudio's
/// `AudioConverter`.
public actor Qwen3ASRStreamingRecognizer: StreamingTranscribing {

    // MARK: - Configuration

    public enum Size: Sendable {
        case b0_6
        case b1_7

        public var modelId: String {
            switch self {
            case .b0_6: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
            case .b1_7: return "aufklarer/Qwen3-ASR-1.7B-MLX-4bit"
            }
        }

        public var label: String {
            switch self {
            case .b0_6: return "0.6B"
            case .b1_7: return "1.7B"
            }
        }
    }

    // MARK: - Tunables
    //
    // Mirrors `speech-swift/StreamingASRConfig` defaults; values chosen so
    // partials refresh roughly every second and a single utterance is
    // capped at ~10 s before a forced split. Token budget is intentionally
    // tight (32) so a single partial decode stays well under the ~300 ms
    // first-word latency Live Captions targets.

    private static let sampleRate: Int = 16_000
    private static let partialInterval: Float = 1.0
    private static let maxSegmentDuration: Float = 10.0
    private static let partialMaxTokens: Int = 32
    private static let finalMaxTokens: Int = 448

    // MARK: - Dependencies

    private let logger = Logger(subsystem: "com.scribe", category: "asr.qwen3.streaming")
    nonisolated private let audioConverter: AudioConverter
    private let size: Size

    // MARK: - Loaded state

    private var asrModel: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var vadProcessor: StreamingVADProcessor?

    // MARK: - Streaming state

    /// All samples received so far that have not been compacted out.
    /// `bufferStartAbs` is the absolute sample index (since session
    /// start) of `samples[0]`.
    private var samples: [Float] = []
    private var bufferStartAbs: Int = 0
    /// Where the VAD processor has consumed up to (absolute index).
    private var processedAbs: Int = 0

    /// Absolute sample index where the current speech run started, or
    /// `nil` if VAD is currently in silence.
    private var speechStartAbs: Int?
    /// Absolute sample index of the most recent partial emission, used
    /// to throttle to `partialInterval`.
    private var lastPartialAbs: Int = 0

    private var committed: String = ""
    private var currentLive: String = ""
    /// Number of finalised utterances since the last MLX cache flush.
    /// Used to bound GPU residue over long-running sessions without
    /// thrashing the cache on every emission. Empirically 8 utterances
    /// leaves room for the encoder/decoder allocation cycle to amortise
    /// while still releasing memory before it accumulates to GB-scale.
    private var finalsSinceCacheFlush: Int = 0

    private var continuation: AsyncStream<LiveCaptionUpdate>.Continuation?
    private var stream: AsyncStream<LiveCaptionUpdate>?

    /// Polls the VAD/ASR loop. Pull cadence (~50 ms) is finer than the
    /// 1 s partial interval so we don't smear partial emissions; ASR
    /// itself dominates wall time on Apple Silicon so the poll is cheap.
    private var processingTask: Task<Void, Never>?

    // MARK: - Init

    public init(size: Size) {
        self.size = size
        // `AudioConverter.init` wants a `Double` sample rate. Cast at the
        // call site so the rest of this file keeps treating sampleRate as
        // an Int for sample-count arithmetic.
        self.audioConverter = AudioConverter(sampleRate: Double(Qwen3ASRStreamingRecognizer.sampleRate))
    }

    // MARK: - StreamingTranscribing

    public var partials: AsyncStream<LiveCaptionUpdate> {
        get async {
            if let stream { return stream }
            let (newStream, newCont) = AsyncStream<LiveCaptionUpdate>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            self.stream = newStream
            self.continuation = newCont
            return newStream
        }
    }

    public func start() async throws {
        let label = size.label
        let needsModels = !testingSkipModelLoad && (asrModel == nil || vadModel == nil)

        if needsModels {
            logger.info("Loading Qwen3-ASR \(label, privacy: .public) streaming engine")

            // Co-load: weights are independent so we let the HF downloader
            // sequence them. Qwen3-ASR pulls ~342 MB / ~700 MB on first run,
            // Silero VAD adds ~40 MB; the call is idempotent thanks to the
            // downloader's skip-if-exists logic.
            let asr = try await Qwen3ASRModel.fromPretrained(
                modelId: size.modelId,
                cacheDir: nil,
                offlineMode: false,
                progressHandler: nil
            )
            let vad = try await SileroVADModel.fromPretrained()

            self.asrModel = asr
            self.vadModel = vad

            // Cap the MLX GPU cache so a long Live Captions session can't
            // balloon to multiple GB — the cache reuses allocations across
            // transcribe() calls, but without a ceiling it grows monotonically
            // for the lifetime of the process. 512 MB is generous for two
            // models that fit in ~700 MB themselves plus the per-call
            // working set.
            MLX.Memory.cacheLimit = 512 * 1024 * 1024
        }

        // Always fresh-arm the per-session pieces — even when models stay
        // loaded across restart, the VAD's internal chunk counter and the
        // processing loop must be re-initialised, otherwise a second start()
        // after a finish() leaves the engine in "loaded but inert" state:
        // appendAudio appends, no drain pulls, no transcription emits, UI
        // shows "listening" forever.
        if let vad = vadModel {
            vadProcessor = StreamingVADProcessor(model: vad)
        }
        resetSessionState()
        startProcessingLoop()
        if needsModels {
            logger.info("Qwen3-ASR \(label, privacy: .public) streaming engine ready")
        }
    }

    public nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        // Resample off the actor — `AudioConverter` is safe to call
        // from the audio thread, same pattern as the Sherpa engines.
        let samples = try audioConverter.resampleBuffer(buffer)
        await self.enqueue(samples)
    }

    public func finish() async throws -> String {
        processingTask?.cancel()
        processingTask = nil

        // Flush whatever the VAD was still holding so a final utterance
        // doesn't get dropped on stop.
        if let vadProcessor {
            let events = vadProcessor.flush()
            for event in events {
                await handleVADEvent(event)
            }
        }

        // If speech was in progress when the user pressed Stop, commit
        // the in-flight partial as a final segment so the SRT export
        // sees it.
        if let speechStartAbs, !currentLive.isEmpty {
            let text = await transcribeSegment(
                fromAbs: speechStartAbs,
                toAbs: processedAbs,
                maxTokens: Self.finalMaxTokens
            )
            if !text.isEmpty {
                appendCommitted(text)
            }
        }

        let cont = await ensureContinuation()
        cont.yield(LiveCaptionUpdate(text: committed, isFinal: true))
        cont.finish()
        self.continuation = nil
        self.stream = nil

        // Reset session state but keep the loaded model in place so a
        // subsequent start() doesn't re-pay the load cost.
        let final = committed
        resetSessionState()
        return final
    }

    public func reset() async throws {
        processingTask?.cancel()
        processingTask = nil
        resetSessionState()
        if let vadModel {
            // Recreating the processor is cheaper than spelunking
            // its internal four-state machine for a reset entry point.
            vadProcessor = StreamingVADProcessor(model: vadModel)
        }
        // Drop any cached intermediate tensors from the prior session so a
        // long-running app doesn't accumulate per-session GPU residue.
        // Guarded on asrModel — without weights loaded MLX hasn't opened
        // the metallib and clearCache would fault.
        if asrModel != nil {
            MLX.Memory.clearCache()
        }
        startProcessingLoop()
    }

    // MARK: - Internal: queue

    private func enqueue(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    private func resetSessionState() {
        samples.removeAll(keepingCapacity: true)
        bufferStartAbs = 0
        processedAbs = 0
        speechStartAbs = nil
        lastPartialAbs = 0
        committed = ""
        currentLive = ""
    }

    // MARK: - Internal: VAD/ASR loop

    private func startProcessingLoop() {
        // Cancel any orphan task first — start() can be called while a
        // previous task is still draining (e.g. user-initiated reset()).
        processingTask?.cancel()
        processingGeneration += 1
        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                // 50 ms is below the 200 ms cadence Nemotron uses but
                // we want partials to fire close to the 1 s mark.
                // VAD chunks are 512 samples / 32 ms so this still
                // processes them in batches.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func drain() async {
        guard let vadProcessor else { return }

        let chunkSize = SileroVADModel.chunkSize
        while available(at: processedAbs) >= chunkSize {
            let localOffset = processedAbs - bufferStartAbs
            let chunk = Array(samples[localOffset ..< localOffset + chunkSize])
            processedAbs += chunkSize
            let events = vadProcessor.process(samples: chunk)
            for event in events {
                await handleVADEvent(event)
            }
            // Mid-utterance partial refresh.
            if let speechStartAbs {
                let sinceLast = processedAbs - lastPartialAbs
                let interval = Int(Self.partialInterval * Float(Self.sampleRate))
                let speechDuration = processedAbs - speechStartAbs
                let maxDuration = Int(Self.maxSegmentDuration * Float(Self.sampleRate))

                if sinceLast >= interval {
                    await emitPartial(from: speechStartAbs, upTo: processedAbs)
                    lastPartialAbs = processedAbs
                }

                // Force-split overlong utterances so a runaway speaker
                // doesn't make the partial slice grow unbounded (and the
                // decode cost with it).
                if speechDuration >= maxDuration {
                    await commitFinal(from: speechStartAbs, upTo: processedAbs)
                    self.speechStartAbs = processedAbs
                    self.lastPartialAbs = processedAbs
                }
            }
        }

        // Compact: drop anything before the earliest live cursor so the
        // buffer doesn't grow over the whole session.
        compactBuffer()
    }

    private func handleVADEvent(_ event: VADEvent) async {
        switch event {
        case .speechStarted(let time):
            speechStartAbs = Int(time * Float(Self.sampleRate))
            lastPartialAbs = speechStartAbs ?? processedAbs
        case .speechEnded(let segment):
            if let start = speechStartAbs {
                let endAbs = min(Int(segment.endTime * Float(Self.sampleRate)),
                                 processedAbs)
                if endAbs > start {
                    await commitFinal(from: start, upTo: endAbs)
                }
            }
            speechStartAbs = nil
        }
    }

    private func emitPartial(from startAbs: Int, upTo endAbs: Int) async {
        let text = await transcribeSegment(
            fromAbs: startAbs,
            toAbs: endAbs,
            maxTokens: Self.partialMaxTokens
        )
        guard !text.isEmpty else { return }
        currentLive = text
        yieldCumulative(isFinal: false)
    }

    private func commitFinal(from startAbs: Int, upTo endAbs: Int) async {
        let text = await transcribeSegment(
            fromAbs: startAbs,
            toAbs: endAbs,
            maxTokens: Self.finalMaxTokens
        )
        guard !text.isEmpty else {
            currentLive = ""
            return
        }
        appendCommitted(text)
        currentLive = ""
        yieldCumulative(isFinal: false)

        // Bounded cache pruning — every N finals we drop the MLX scratch
        // pool. Without this, long sessions leak GPU memory monotonically
        // because MLX retains every per-call allocation up to cacheLimit
        // and reallocates lazily, so apparent residency grows for hours
        // before steady state.
        finalsSinceCacheFlush += 1
        if finalsSinceCacheFlush >= 8 {
            finalsSinceCacheFlush = 0
            MLX.Memory.clearCache()
        }
    }

    private func appendCommitted(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if committed.isEmpty {
            committed = trimmed
        } else {
            // Qwen3-ASR emits sentence-final punctuation natively so we
            // just glue with a space — Mandarin segments end in 。/？/！
            // already and don't need an inter-segment space.
            let needsSpace = !"。？！，、；：.,!?;:".contains(committed.last!)
            committed += (needsSpace ? " " : "") + trimmed
        }
    }

    private func yieldCumulative(isFinal: Bool) {
        let cumulative: String
        if currentLive.isEmpty {
            cumulative = committed
        } else if committed.isEmpty {
            cumulative = currentLive
        } else {
            cumulative = committed + " " + currentLive
        }
        let cont = continuation ?? Self.makeFallbackContinuation(for: self)
        cont?.yield(LiveCaptionUpdate(text: cumulative, isFinal: isFinal))
    }

    /// Slice `samples[startAbs…endAbs)` and feed it to Qwen3-ASR. The
    /// caller is responsible for ensuring the slice still lives in the
    /// buffer (i.e., `startAbs >= bufferStartAbs`).
    private func transcribeSegment(
        fromAbs startAbs: Int,
        toAbs endAbs: Int,
        maxTokens: Int
    ) async -> String {
        guard let asrModel else { return "" }
        guard endAbs > startAbs else { return "" }

        let startLocal = max(0, startAbs - bufferStartAbs)
        let endLocal = min(samples.count, endAbs - bufferStartAbs)
        guard endLocal > startLocal else { return "" }

        let slice = Array(samples[startLocal ..< endLocal])

        // `Qwen3ASRModel.transcribe` is synchronous and not thread-safe;
        // actor isolation gives us mutual exclusion automatically.
        let text = asrModel.transcribe(
            audio: slice,
            sampleRate: Self.sampleRate,
            language: nil,
            maxTokens: maxTokens,
            context: nil
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Free samples that no live cursor can still need. We keep
    /// everything from `min(processedAbs, speechStartAbs)` forward.
    private func compactBuffer() {
        let keepFromAbs = min(processedAbs, speechStartAbs ?? processedAbs)
        let dropCount = keepFromAbs - bufferStartAbs
        guard dropCount > 0, dropCount <= samples.count else { return }
        samples.removeFirst(dropCount)
        bufferStartAbs += dropCount
    }

    private func available(at abs: Int) -> Int {
        let localOffset = abs - bufferStartAbs
        guard localOffset >= 0 else { return 0 }
        return samples.count - localOffset
    }

    // MARK: - Continuation helpers

    private func ensureContinuation() async -> AsyncStream<LiveCaptionUpdate>.Continuation {
        if let continuation { return continuation }
        _ = await partials  // forces creation via `partials` getter
        return continuation!
    }

    /// Used by the synchronous `yieldCumulative` path when no consumer
    /// has subscribed yet. Returns `nil` rather than blocking; partials
    /// emitted before a subscriber attaches are simply dropped, which
    /// matches the `bufferingNewest(1)` policy on the stream.
    private static func makeFallbackContinuation(
        for actor: Qwen3ASRStreamingRecognizer
    ) -> AsyncStream<LiveCaptionUpdate>.Continuation? {
        return nil
    }

    // MARK: - Test hooks
    //
    // These exist so `Qwen3StreamingLifecycleTests` can exercise the
    // start/finish/start lifecycle (the actual regression we're guarding
    // against) without paying the ~500 MB model download tax. They are
    // not part of any public protocol and should not be used at runtime.

    /// Marks the model fields as if `start()` had loaded them. Sentinel
    /// values are intentionally `nil` placeholders dressed up — they will
    /// crash if any real transcription pipeline runs against them — so
    /// only the lifecycle test should poke them.
    internal func testingMarkModelsLoaded() {
        // We can't construct real Qwen3ASRModel/SileroVADModel without
        // weights, but `start()` only branches on nil-vs-non-nil. We
        // satisfy that branch by leaving them nil and instead skipping
        // the model load entirely via the test-only flag below.
        testingSkipModelLoad = true
    }

    /// When set, `start()` treats the engine as already loaded and only
    /// runs the lifecycle side of the function (VAD reset, processing
    /// loop arming). The test sets this so we can drive the failure
    /// path without weights.
    private var testingSkipModelLoad: Bool = false

    internal var testingIsProcessing: Bool {
        guard let task = processingTask else { return false }
        return !task.isCancelled
    }

    /// Monotonic generation counter incremented every time
    /// `startProcessingLoop()` arms a new task. The test compares this
    /// across `start()` / `reset()` calls to verify a *new* task was
    /// installed rather than the old one being reused.
    private var processingGeneration: Int = 0

    internal var testingProcessingTaskID: Int { processingGeneration }
}

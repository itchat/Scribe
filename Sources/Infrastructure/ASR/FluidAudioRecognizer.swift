import Foundation
import os
import FluidAudio
import Domain
import Protocols

/// Speech recognizer using FluidAudio's Parakeet v2 (English-only) via CoreML on Neural Engine.
///
/// Replaces the Python `ParakeetRecognizer` which used MLX (GPU).
/// Uses Swift `actor` for thread safety instead of Python's file locks + process-level singleton.
public actor FluidAudioRecognizer: SpeechRecognizing {

    private var asrManager: AsrManager?
    private var models: AsrModels?
    private let logger = Logger(subsystem: "com.scribe", category: "asr")

    public init() {}

    // MARK: - SpeechRecognizing

    public func transcribe(
        audioAt url: URL,
        progress: (any Protocols.ProgressReporting)?
    ) async throws -> TranscriptionResult {
        let manager = try await ensureModelLoaded(progress: progress)

        progress?.reportStatus("Transcribing audio...")

        // FluidAudio 0.15 threads the TDT decoder state through the caller so
        // a streaming consumer can carry it across chunks. The burn pipeline
        // transcribes each file in one shot, so a fresh state per call is
        // correct — carrying it over would leak the previous file's decoder
        // context into the next item in the queue.
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &decoderState)

        // Timings are public (they are the only perf instrumentation in the
        // app); the transcript itself is the user's speech and stays private.
        logger.info("Transcription completed: \(result.text.count, privacy: .public) chars, \(result.duration, format: .fixed(precision: 1), privacy: .public)s audio, \(result.rtfx, format: .fixed(precision: 0), privacy: .public)x realtime")
        logger.debug("Transcript preview: \(result.text.prefix(50), privacy: .private)")

        return convertResult(result)
    }

    // MARK: - Model Management

    /// Whether the ASR model is downloaded and ready.
    public var isModelReady: Bool {
        models != nil
    }

    /// Release the loaded CoreML models, keeping the on-disk cache.
    ///
    /// `ASRModelService` holds this recognizer for the whole app lifetime, so
    /// without an explicit unload Parakeet's ~1.2 GB stayed resident after the
    /// burn queue drained. A user who transcribed a video and then opened Live
    /// Captions with Qwen3 1.7B carried ~2 GB of weights at once — enough to
    /// push an 8 GB machine into swap. The next `transcribe` reloads from the
    /// local cache, so the cost of being wrong here is a reload, not a
    /// re-download.
    public func unload() {
        guard asrManager != nil || models != nil else { return }
        asrManager = nil
        models = nil
        logger.info("ASR models unloaded")
    }

    /// Whether the model files exist on disk (but may not be loaded).
    public static func isModelCached(version: AsrModelVersion = .v2) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    /// Download the model if not already cached.
    public func downloadModelIfNeeded(
        version: AsrModelVersion = .v2,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if Self.isModelCached(version: version) {
            logger.info("ASR model v2 already cached")
            return
        }

        logger.info("Downloading ASR model v2...")

        if let progressHandler {
            let handler: ProgressHandler = { progress in
                progressHandler(progress.fractionCompleted)
            }
            try await AsrModels.download(version: version, progressHandler: handler)
        } else {
            try await AsrModels.download(version: version)
        }
        logger.info("ASR model download completed")
    }

    // MARK: - Private

    private func ensureModelLoaded(progress: (any Protocols.ProgressReporting)?) async throws -> AsrManager {
        if let manager = asrManager {
            return manager
        }

        let needsDownload = !Self.isModelCached(version: .v2)

        if needsDownload {
            progress?.reportStatus("Downloading ASR model (~1.2 GB)...")
            logger.info("Downloading ASR model v2...")
        } else {
            progress?.reportStatus("Loading ASR model...")
            logger.info("Loading ASR model v2 from cache...")
        }

        let handler: ProgressHandler = { [weak progress] dlProgress in
            let percent = Int(dlProgress.fractionCompleted * 100)
            progress?.reportStatus("Downloading ASR model... \(percent)%")
            // Map download progress to the 10-20% pipeline range
            let mapped = 10 + Int(dlProgress.fractionCompleted * 10)
            progress?.reportProgress(mapped)
        }

        let loadedModels = try await AsrModels.downloadAndLoad(
            version: .v2,
            progressHandler: handler
        )

        progress?.reportStatus("Initializing ASR engine...")
        let manager = AsrManager(config: .default)
        try await manager.loadModels(loadedModels)

        self.models = loadedModels
        self.asrManager = manager

        logger.info("ASR model loaded successfully")
        return manager
    }

    /// Convert FluidAudio's `ASRResult` to our domain `TranscriptionResult`.
    private func convertResult(_ result: ASRResult) -> TranscriptionResult {
        // Use token timings to build sentence-level segments with proper timing
        if let timings = result.tokenTimings, !timings.isEmpty {
            let segments = buildSegmentsFromTokens(timings, fullText: result.text)
            return TranscriptionResult(text: result.text, segments: segments)
        }

        // No token timings — fall back to char-weighted chunking so a single
        // long sentence doesn't paint a wall of text on screen. See
        // `SentenceChunker` for the chunking + weighting policy.
        let segments = SentenceChunker.makeSegments(text: result.text, duration: result.duration)
        return TranscriptionResult(text: result.text, segments: segments)
    }

    /// Build sentence segments from token timings.
    /// Uses the token's original text (preserving spaces) and groups by sentence-ending punctuation.
    private func buildSegmentsFromTokens(_ timings: [TokenTiming], fullText: String) -> [TranscriptionSegment] {
        var segments: [TranscriptionSegment] = []
        var currentTokens: [String] = []
        var segmentStart: TimeInterval = 0
        var segmentEnd: TimeInterval = 0

        let sentenceEnders: Set<Character> = [".", "!", "?"]

        for timing in timings {
            let token = timing.token
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            if currentTokens.isEmpty {
                segmentStart = timing.startTime
            }
            currentTokens.append(token)
            segmentEnd = timing.endTime

            // Check if this token ends a sentence
            let trimmedToken = token.trimmingCharacters(in: .whitespaces)
            if let lastChar = trimmedToken.last, sentenceEnders.contains(lastChar) {
                let text = currentTokens.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(TranscriptionSegment(
                        text: text,
                        start: segmentStart,
                        end: segmentEnd
                    ))
                }
                currentTokens = []
            }
        }

        // Remaining tokens
        if !currentTokens.isEmpty {
            let text = currentTokens.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptionSegment(
                    text: text,
                    start: segmentStart,
                    end: segmentEnd
                ))
            }
        }

        return segments
    }

}

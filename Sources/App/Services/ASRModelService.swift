import SwiftUI
import Foundation
import os
import Infrastructure

/// Manages the ASR model lifecycle: cache status, download progress, readiness.
///
/// SRP: Only concerned with the model's lifecycle — not transcription, not UI.
@Observable
@MainActor
final class ASRModelService {
    var isReady: Bool
    var isDownloading: Bool = false
    var downloadProgress: Double = 0
    /// Last download failure, or nil. Set so the failure is at least
    /// observable; see `download()`.
    var lastError: String?

    private let recognizer: FluidAudioRecognizer
    private let logger = Logger(subsystem: "com.scribe", category: "asr.model-service")

    init(recognizer: FluidAudioRecognizer = FluidAudioRecognizer()) {
        self.recognizer = recognizer
        self.isReady = FluidAudioRecognizer.isModelCached(version: .v2)
    }

    func download() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0

        Task {
            do {
                try await recognizer.downloadModelIfNeeded(version: .v2) { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress
                    }
                }
                isReady = true
                lastError = nil
            } catch {
                // Previously swallowed entirely, so a failed 1.2 GB download
                // looked identical to never having started one. Recorded here
                // and logged; surfacing it in the sheet is tracked in
                // docs/ui-improvements.md.
                logger.error("ASR model download failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
            isDownloading = false
        }
    }

    func refresh() {
        isReady = FluidAudioRecognizer.isModelCached(version: .v2)
    }

    /// Release the loaded models once the burn queue is idle.
    func unloadModels() async {
        await recognizer.unload()
    }

    /// Expose the recognizer for the pipeline (DIP via protocol at call site).
    var speechRecognizer: FluidAudioRecognizer { recognizer }
}

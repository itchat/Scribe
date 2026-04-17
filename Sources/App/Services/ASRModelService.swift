import SwiftUI
import Foundation
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

    private let recognizer: FluidAudioRecognizer

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
            } catch {
                // surface via the calling ViewModel's error path if needed
            }
            isDownloading = false
        }
    }

    func refresh() {
        isReady = FluidAudioRecognizer.isModelCached(version: .v2)
    }

    /// Expose the recognizer for the pipeline (DIP via protocol at call site).
    var speechRecognizer: FluidAudioRecognizer { recognizer }
}

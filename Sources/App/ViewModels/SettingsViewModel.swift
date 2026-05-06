import SwiftUI
import Domain
import Infrastructure

/// View model for the settings sheet.
@Observable
@MainActor
final class SettingsViewModel {
    var translationMode: TranslationMode
    var baseURL: String
    var apiKey: String
    var model: String
    var customPrompt: String
    var maxCharsPerBatch: Int
    var maxEntriesPerBatch: Int
    var skipSubtitleBurning: Bool
    var enableGoogleFallback: Bool
    /// Captured so saving Settings doesn't reset Live Captions / offline ASR
    /// engine choices that the user picked from their respective UIs.
    var liveCaptionEngine: LiveCaptionEngine
    var offlineASREngine: OfflineASREngine
    var subtitleStyle: SubtitleStyle

    init(config: AppConfig) {
        self.translationMode = config.translationMode
        self.baseURL = config.baseURL
        self.apiKey = config.apiKey
        self.model = config.model
        self.customPrompt = config.customPrompt
        self.maxCharsPerBatch = config.maxCharsPerBatch
        self.maxEntriesPerBatch = config.maxEntriesPerBatch
        self.skipSubtitleBurning = config.skipSubtitleBurning
        self.enableGoogleFallback = config.enableGoogleFallback
        self.liveCaptionEngine = config.liveCaptionEngine
        self.offlineASREngine = config.offlineASREngine
        self.subtitleStyle = config.subtitleStyle
    }

    func toConfig() -> AppConfig {
        AppConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            customPrompt: customPrompt,
            maxCharsPerBatch: maxCharsPerBatch,
            maxEntriesPerBatch: maxEntriesPerBatch,
            enableGoogleFallback: enableGoogleFallback,
            skipSubtitleBurning: skipSubtitleBurning,
            translationMode: translationMode,
            subtitleStyle: subtitleStyle,
            liveCaptionEngine: liveCaptionEngine,
            offlineASREngine: offlineASREngine
        )
    }
}

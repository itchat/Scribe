import SwiftUI
import Domain
import Infrastructure

/// View model for the settings sheet.
@Observable
@MainActor
final class SettingsViewModel {
    var translationEngine: TranslationEngine
    var baseURL: String
    var apiKey: String
    var model: String
    var customPrompt: String
    var maxCharsPerBatch: Int
    var maxEntriesPerBatch: Int
    var skipTranslation: Bool
    var skipSubtitleBurning: Bool
    var enableGoogleFallback: Bool

    init(config: AppConfig) {
        self.translationEngine = config.translationEngine
        self.baseURL = config.baseURL
        self.apiKey = config.apiKey
        self.model = config.model
        self.customPrompt = config.customPrompt
        self.maxCharsPerBatch = config.maxCharsPerBatch
        self.maxEntriesPerBatch = config.maxEntriesPerBatch
        self.skipTranslation = config.skipTranslation
        self.skipSubtitleBurning = config.skipSubtitleBurning
        self.enableGoogleFallback = config.enableGoogleFallback
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
            skipTranslation: skipTranslation,
            skipSubtitleBurning: skipSubtitleBurning,
            translationEngine: translationEngine
        )
    }
}

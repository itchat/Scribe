import SwiftUI
import Domain
import Infrastructure

/// View model for the settings sheet.
///
/// SRP: holds the editing state for the fields the Settings inspector owns,
/// and writes back only those fields — see `apply(to:)`.
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
        self.offlineASREngine = config.offlineASREngine
        self.subtitleStyle = config.subtitleStyle
    }

    /// Write the inspector's fields into `config`, leaving every other field
    /// as it is.
    ///
    /// This used to build a fresh `AppConfig` from the snapshot taken when the
    /// inspector opened. Fields the inspector doesn't edit were therefore
    /// written back at their old values: switching the Live Captions engine
    /// while the inspector was open was undone by the next keystroke here, and
    /// the retry settings, which have no control at all, were reset to their
    /// defaults on every save.
    func apply(to config: inout AppConfig) {
        config.baseURL = baseURL
        config.apiKey = apiKey
        config.model = model
        config.customPrompt = customPrompt
        config.maxCharsPerBatch = maxCharsPerBatch
        config.maxEntriesPerBatch = maxEntriesPerBatch
        config.enableGoogleFallback = enableGoogleFallback
        config.skipSubtitleBurning = skipSubtitleBurning
        config.translationMode = translationMode
        config.subtitleStyle = subtitleStyle
        config.offlineASREngine = offlineASREngine
    }
}

import Foundation
import Domain

/// Application configuration — Codable value type with file persistence.
///
/// DIP fix: Replaces the Python `ConfigManager` singleton.
/// Injected via `@Environment` in SwiftUI, or passed directly in Core types.
public struct AppConfig: Codable, Sendable {

    // MARK: - API

    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var customPrompt: String

    // MARK: - Batch

    public var maxCharsPerBatch: Int
    public var maxEntriesPerBatch: Int

    // MARK: - Retry

    public var maxRetries: Int
    public var retryBaseDelay: Double
    public var retryMaxDelay: Double
    public var enableGoogleFallback: Bool

    // MARK: - Processing

    /// Whether the burn pipeline writes a video with subtitles burned in
    /// (`false`) or only emits SRT files (`true`).
    public var skipSubtitleBurning: Bool

    /// Single 3-way switch replacing the old `skipTranslation: Bool` +
    /// `translationEngine: TranslationEngine` pair. `.off` skips
    /// translation entirely; `.openAI` / `.google` route through the
    /// matching translator.
    public var translationMode: TranslationMode

    /// How burned subtitles look on the output video. Concrete values
    /// (font name, point size, colours, position) — the editor in
    /// Settings writes into this struct directly.
    public var subtitleStyle: SubtitleStyle

    // MARK: - Live Captions

    /// Which streaming ASR engine the Live Captions window starts with.
    public var liveCaptionEngine: LiveCaptionEngine

    // MARK: - Offline (burn pipeline) ASR

    /// Which offline ASR engine the burn pipeline uses to transcribe a
    /// video file's audio track. Default Parakeet v2 (English, fastest);
    /// users with Chinese / mixed-language content switch to a Qwen3 variant.
    public var offlineASREngine: OfflineASREngine

    // MARK: - Init with defaults

    public init(
        baseURL: String = Constants.defaultOpenAIBaseURL,
        apiKey: String = "",
        model: String = Constants.defaultOpenAIModel,
        customPrompt: String = Constants.defaultTranslationPrompt,
        maxCharsPerBatch: Int = Constants.defaultMaxCharsPerBatch,
        maxEntriesPerBatch: Int = Constants.defaultMaxEntriesPerBatch,
        maxRetries: Int = Constants.defaultMaxRetries,
        retryBaseDelay: Double = Constants.defaultRetryBaseDelay,
        retryMaxDelay: Double = Constants.defaultRetryMaxDelay,
        enableGoogleFallback: Bool = true,
        skipSubtitleBurning: Bool = false,
        translationMode: TranslationMode = .openAI,
        subtitleStyle: SubtitleStyle = SubtitleStyle(),
        liveCaptionEngine: LiveCaptionEngine = .nemotron,
        offlineASREngine: OfflineASREngine = .parakeetV2
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.customPrompt = customPrompt
        self.maxCharsPerBatch = maxCharsPerBatch
        self.maxEntriesPerBatch = maxEntriesPerBatch
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.retryMaxDelay = retryMaxDelay
        self.enableGoogleFallback = enableGoogleFallback
        self.skipSubtitleBurning = skipSubtitleBurning
        self.translationMode = translationMode
        self.subtitleStyle = subtitleStyle
        self.liveCaptionEngine = liveCaptionEngine
        self.offlineASREngine = offlineASREngine
    }

    // Custom decoder for backward compatibility with older config files
    // that don't contain newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? Constants.defaultOpenAIBaseURL
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? Constants.defaultOpenAIModel
        self.customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? Constants.defaultTranslationPrompt
        self.maxCharsPerBatch = try c.decodeIfPresent(Int.self, forKey: .maxCharsPerBatch) ?? Constants.defaultMaxCharsPerBatch
        self.maxEntriesPerBatch = try c.decodeIfPresent(Int.self, forKey: .maxEntriesPerBatch) ?? Constants.defaultMaxEntriesPerBatch
        self.maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? Constants.defaultMaxRetries
        self.retryBaseDelay = try c.decodeIfPresent(Double.self, forKey: .retryBaseDelay) ?? Constants.defaultRetryBaseDelay
        self.retryMaxDelay = try c.decodeIfPresent(Double.self, forKey: .retryMaxDelay) ?? Constants.defaultRetryMaxDelay
        self.enableGoogleFallback = try c.decodeIfPresent(Bool.self, forKey: .enableGoogleFallback) ?? true
        self.skipSubtitleBurning = try c.decodeIfPresent(Bool.self, forKey: .skipSubtitleBurning) ?? false

        // translationMode is the canonical field. Legacy configs still
        // carry `skipTranslation: Bool` + `translationEngine: TranslationEngine`
        // pre-consolidation — fold them into the new mode here so users
        // upgrading from earlier builds keep their settings.
        if let mode = try c.decodeIfPresent(TranslationMode.self, forKey: .translationMode) {
            self.translationMode = mode
        } else {
            let legacySkip = try c.decodeIfPresent(Bool.self, forKey: .legacySkipTranslation) ?? false
            let legacyEngine = try c.decodeIfPresent(TranslationEngine.self, forKey: .legacyTranslationEngine) ?? .openAI
            if legacySkip {
                self.translationMode = .off
            } else {
                self.translationMode = legacyEngine == .google ? .google : .openAI
            }
        }

        self.subtitleStyle = try c.decodeIfPresent(SubtitleStyle.self, forKey: .subtitleStyle) ?? SubtitleStyle()
        self.liveCaptionEngine = try c.decodeIfPresent(LiveCaptionEngine.self, forKey: .liveCaptionEngine) ?? .nemotron
        self.offlineASREngine = try c.decodeIfPresent(OfflineASREngine.self, forKey: .offlineASREngine) ?? .parakeetV2
    }

    /// Explicit CodingKeys so we can keep legacy field names available to
    /// the back-compat decoder above without re-emitting them on save.
    enum CodingKeys: String, CodingKey {
        case baseURL, apiKey, model, customPrompt
        case maxCharsPerBatch, maxEntriesPerBatch
        case maxRetries, retryBaseDelay, retryMaxDelay, enableGoogleFallback
        case skipSubtitleBurning
        case translationMode
        case subtitleStyle
        case liveCaptionEngine
        case offlineASREngine
        // Legacy fields — read-only; never re-encoded.
        case legacySkipTranslation = "skipTranslation"
        case legacyTranslationEngine = "translationEngine"
    }

    /// Encode only the canonical fields. The two legacy keys
    /// (`skipTranslation` / `translationEngine`) exist solely for the
    /// back-compat decoder to read older configs and must never be
    /// re-emitted, otherwise round-tripping would resurrect them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode(customPrompt, forKey: .customPrompt)
        try c.encode(maxCharsPerBatch, forKey: .maxCharsPerBatch)
        try c.encode(maxEntriesPerBatch, forKey: .maxEntriesPerBatch)
        try c.encode(maxRetries, forKey: .maxRetries)
        try c.encode(retryBaseDelay, forKey: .retryBaseDelay)
        try c.encode(retryMaxDelay, forKey: .retryMaxDelay)
        try c.encode(enableGoogleFallback, forKey: .enableGoogleFallback)
        try c.encode(skipSubtitleBurning, forKey: .skipSubtitleBurning)
        try c.encode(translationMode, forKey: .translationMode)
        try c.encode(subtitleStyle, forKey: .subtitleStyle)
        try c.encode(liveCaptionEngine, forKey: .liveCaptionEngine)
        try c.encode(offlineASREngine, forKey: .offlineASREngine)
    }

    // MARK: - Persistence

    /// Default config file URL: `~/Library/Application Support/Scribe/config.json`
    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Constants.configDirName)
            .appendingPathComponent(Constants.configFileName)
    }

    public func save(to url: URL? = nil) throws {
        let fileURL = url ?? Self.defaultFileURL
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func load(from url: URL? = nil) throws -> AppConfig {
        let fileURL = url ?? defaultFileURL
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    // MARK: - Validation

    /// Validate configuration for the active translation mode. Returns an
    /// array of human-readable issue descriptions, empty if valid.
    public func validate(for mode: TranslationMode) -> [String] {
        var issues: [String] = []

        if mode == .openAI && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("API key is required for OpenAI translation")
        }

        return issues
    }
}

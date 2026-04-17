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

    public var skipTranslation: Bool
    public var skipSubtitleBurning: Bool
    public var translationEngine: TranslationEngine

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
        skipTranslation: Bool = false,
        skipSubtitleBurning: Bool = false,
        translationEngine: TranslationEngine = .openAI
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
        self.skipTranslation = skipTranslation
        self.skipSubtitleBurning = skipSubtitleBurning
        self.translationEngine = translationEngine
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
        self.skipTranslation = try c.decodeIfPresent(Bool.self, forKey: .skipTranslation) ?? false
        self.skipSubtitleBurning = try c.decodeIfPresent(Bool.self, forKey: .skipSubtitleBurning) ?? false
        self.translationEngine = try c.decodeIfPresent(TranslationEngine.self, forKey: .translationEngine) ?? .openAI
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

    /// Validate configuration for a specific translation engine.
    /// Returns an array of human-readable issue descriptions, empty if valid.
    public func validate(for engine: TranslationEngine) -> [String] {
        var issues: [String] = []

        if engine == .openAI && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("API key is required for OpenAI translation")
        }

        return issues
    }
}

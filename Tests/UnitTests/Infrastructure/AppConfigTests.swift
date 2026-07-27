import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

/// In-memory `SecretStoring` so config tests never touch the real login
/// Keychain. Without this they do — an earlier run of this suite left a test
/// API key in the developer's keychain and the next run read it back,
/// producing a failure that had nothing to do with the code under test.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(initial: String? = nil) { key = initial }

    func readAPIKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    @discardableResult
    func writeAPIKey(_ newKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        key = newKey.isEmpty ? nil : newKey
        return true
    }
}

@Suite("AppConfig")
struct AppConfigTests {

    @Test("Default config has sensible defaults")
    func defaults() {
        let config = AppConfig()
        #expect(config.baseURL == Constants.defaultOpenAIBaseURL)
        #expect(config.apiKey.isEmpty)
        #expect(config.model == Constants.defaultOpenAIModel)
        #expect(config.translationMode == .openAI)
        #expect(!config.skipSubtitleBurning)
        #expect(config.enableGoogleFallback)
        #expect(config.subtitleStyle == SubtitleStyle())
    }

    @Test("Codable round-trip preserves all fields except the secret")
    func codableRoundTrip() throws {
        var config = AppConfig()
        config.apiKey = "test-key-123"
        config.model = "gpt-4o"
        config.translationMode = .off
        config.maxCharsPerBatch = 2000

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        // The API key is deliberately absent from the encoded form — it lives
        // in the Keychain, not in a 0644 JSON file.
        #expect(decoded.apiKey.isEmpty)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("test-key-123"), "the API key must never be serialised to disk")

        #expect(decoded.model == "gpt-4o")
        #expect(decoded.translationMode == .off)
        #expect(decoded.maxCharsPerBatch == 2000)
    }

    @Test("Saves and loads from file")
    func saveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")
        let secrets = InMemorySecretStore()

        var original = AppConfig()
        original.apiKey = "my-secret-key"
        original.skipSubtitleBurning = true
        try original.save(to: filePath, secrets: secrets)

        let loaded = try AppConfig.load(from: filePath, secrets: secrets)
        #expect(loaded.apiKey == "my-secret-key")
        #expect(loaded.skipSubtitleBurning == true)
    }

    @Test("Config file is written owner-readable only")
    func configFileIsPrivate() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")
        try AppConfig().save(to: filePath, secrets: InMemorySecretStore())

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath.path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value == 0o600, "config.json must not be group/world readable")
    }

    /// Upgrade path: a config written before the key moved to the Keychain
    /// still has it in plaintext. Loading must adopt it, store it, and strip
    /// it from the file.
    @Test("Migrates a legacy plaintext API key out of the config file")
    func migratesLegacyPlaintextKey() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")
        let legacyJSON = """
        {
          "apiKey" : "sk-legacy-plaintext",
          "baseURL" : "https://api.openai.com",
          "model" : "gpt-4o"
        }
        """
        try legacyJSON.write(to: filePath, atomically: true, encoding: .utf8)

        let secrets = InMemorySecretStore()
        let loaded = try AppConfig.load(from: filePath, secrets: secrets)

        #expect(loaded.apiKey == "sk-legacy-plaintext", "the existing key must not be lost on upgrade")
        #expect(secrets.readAPIKey() == "sk-legacy-plaintext", "the key must be moved into the secret store")

        let rewritten = try String(contentsOf: filePath, encoding: .utf8)
        #expect(!rewritten.contains("sk-legacy-plaintext"), "the plaintext key must be stripped from disk")
    }

    /// The secret store wins once migration has happened.
    @Test("Prefers the stored key over anything left in the file")
    func storedKeyWins() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")
        try #"{ "apiKey" : "stale-from-file" }"#.write(to: filePath, atomically: true, encoding: .utf8)

        let secrets = InMemorySecretStore(initial: "current-from-keychain")
        let loaded = try AppConfig.load(from: filePath, secrets: secrets)
        #expect(loaded.apiKey == "current-from-keychain")
    }

    @Test("Load returns default config when file is missing")
    func loadMissingFile() throws {
        let bogusPath = URL(filePath: "/tmp/nonexistent_\(UUID().uuidString).json")
        let config = (try? AppConfig.load(from: bogusPath, secrets: InMemorySecretStore())) ?? AppConfig()
        #expect(config.apiKey.isEmpty)
        #expect(config.baseURL == Constants.defaultOpenAIBaseURL)
    }

    @Test("Validates API key is not empty when OpenAI is used")
    func validatesAPIKey() {
        var config = AppConfig()
        config.apiKey = ""
        let issues = config.validate(for: .openAI)
        #expect(!issues.isEmpty)
        #expect(issues.first?.contains("API key") == true)
    }

    @Test("Validation passes for Google without API key")
    func googleNeedsNoKey() {
        var config = AppConfig()
        config.apiKey = ""
        let issues = config.validate(for: .google)
        #expect(issues.isEmpty)
    }

    /// `baseURL` is a free-text field that auto-saves on every keystroke and
    /// used to reach a force-unwrapped `URL(string:)` in `OpenAITranslator`,
    /// crashing the app on a value that was already persisted to disk.
    @Test("Rejects malformed base URLs",
          arguments: ["not a url", "", "   ", "http://", "ht tp://x.test"])
    func rejectsMalformedBaseURL(bad: String) {
        var config = AppConfig()
        config.apiKey = "sk-test"
        config.baseURL = bad
        let issues = config.validate(for: .openAI)
        #expect(!issues.isEmpty, "\"\(bad)\" should be rejected")
        #expect(issues.contains { $0.contains("Base URL") })
    }

    @Test("Accepts well-formed base URLs with and without /v1",
          arguments: ["https://api.openai.com", "https://api.openai.com/v1", "http://localhost:1234"])
    func acceptsValidBaseURL(good: String) {
        var config = AppConfig()
        config.apiKey = "sk-test"
        config.baseURL = good
        #expect(config.validate(for: .openAI).isEmpty, "\"\(good)\" should be accepted")
    }

    // MARK: - Backward compat for old translation fields

    @Test("Legacy skipTranslation:true → translationMode .off after upgrade")
    func legacySkipTranslationDecodesToOff() throws {
        let json = """
        {
          "skipTranslation": true,
          "translationEngine": "OpenAI",
          "skipSubtitleBurning": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.translationMode == .off)
    }

    @Test("Legacy translationEngine:Google decodes to translationMode .google")
    func legacyTranslationEngineGoogleDecodesToGoogle() throws {
        let json = """
        {
          "skipTranslation": false,
          "translationEngine": "Google"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.translationMode == .google)
    }

    @Test("Legacy translationEngine:OpenAI decodes to translationMode .openAI")
    func legacyTranslationEngineOpenAIDecodesToOpenAI() throws {
        let json = """
        {
          "skipTranslation": false,
          "translationEngine": "OpenAI"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.translationMode == .openAI)
    }

    @Test("New translationMode field takes precedence over legacy fields")
    func newFieldWinsOverLegacy() throws {
        let json = """
        {
          "skipTranslation": true,
          "translationEngine": "OpenAI",
          "translationMode": "Google"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.translationMode == .google)
    }

    // MARK: - Offline ASR engine

    @Test("Default offline ASR engine is Parakeet v2")
    func defaultOfflineASREngineIsParakeet() {
        let config = AppConfig()
        #expect(config.offlineASREngine == .parakeetV2)
    }

    @Test("Decoding JSON without offlineASREngine field defaults to Parakeet v2")
    func decodeMissingOfflineASREngineFieldDefaultsToParakeet() throws {
        // Simulates a config.json written by an older build that pre-dates
        // this field. Forward-compatibility: unknown-fields-as-defaults.
        let json = """
        {
          "baseURL": "https://api.openai.com",
          "apiKey": "",
          "model": "gpt-4o-mini",
          "customPrompt": "translate",
          "maxCharsPerBatch": 1000,
          "maxEntriesPerBatch": 50,
          "maxRetries": 3,
          "retryBaseDelay": 1.0,
          "retryMaxDelay": 30.0,
          "enableGoogleFallback": true,
          "skipTranslation": false,
          "skipSubtitleBurning": false,
          "translationEngine": "OpenAI",
          "liveCaptionEngine": "Nemotron 0.6B"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.offlineASREngine == .parakeetV2)
    }

    @Test("Decoding JSON with offlineASREngine = Qwen3 1.7B preserves the choice")
    func decodeOfflineASREngineQwen3Large() throws {
        var original = AppConfig()
        original.offlineASREngine = .qwen3_1_7B
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.offlineASREngine == .qwen3_1_7B)
    }

    @Test("Decoding JSON with offlineASREngine = Qwen3 0.6B preserves the choice")
    func decodeOfflineASREngineQwen3Small() throws {
        var original = AppConfig()
        original.offlineASREngine = .qwen3_0_6B
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.offlineASREngine == .qwen3_0_6B)
    }

    // MARK: - Full disk round-trip for every Settings-editable field

    @Test("Every Settings-editable field round-trips through save/load on disk")
    func everyEditableFieldRoundTripsToDisk() throws {
        // Mirrors what `SettingsViewModel.toConfig()` produces after the user
        // edits each field in `SettingsInspector`. If any of these regress,
        // the user's edits would silently disappear after relaunch.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("config.json")
        let secrets = InMemorySecretStore()

        var edited = AppConfig()
        edited.baseURL = "https://custom.openai.proxy/v1"
        edited.apiKey = "sk-rt-1234567890"
        edited.model = "gpt-4o-2026-05"
        edited.customPrompt = "Translate every line to formal Chinese."
        edited.maxCharsPerBatch = 4321
        edited.maxEntriesPerBatch = 87
        edited.skipSubtitleBurning = true
        edited.translationMode = .google
        edited.enableGoogleFallback = false
        edited.liveCaptionEngine = .paraformerTrilingual
        edited.offlineASREngine = .qwen3_1_7B
        edited.subtitleStyle = SubtitleStyle(
            fontName: "Helvetica Neue",
            fontSize: 24,
            primaryColorARGB: 0xFF000000,
            outlineColorARGB: 0xFFFFFFFF,
            borderStyle: .opaqueBox,
            alignment: .topCenter,
            marginVertical: 50,
            marginHorizontal: 80
        )

        try edited.save(to: filePath, secrets: secrets)
        let reloaded = try AppConfig.load(from: filePath, secrets: secrets)

        #expect(reloaded.baseURL == "https://custom.openai.proxy/v1")
        #expect(reloaded.apiKey == "sk-rt-1234567890")
        #expect(reloaded.model == "gpt-4o-2026-05")
        #expect(reloaded.customPrompt == "Translate every line to formal Chinese.")
        #expect(reloaded.maxCharsPerBatch == 4321)
        #expect(reloaded.maxEntriesPerBatch == 87)
        #expect(reloaded.skipSubtitleBurning == true)
        #expect(reloaded.translationMode == .google)
        #expect(reloaded.enableGoogleFallback == false)
        #expect(reloaded.liveCaptionEngine == .paraformerTrilingual)
        #expect(reloaded.offlineASREngine == .qwen3_1_7B)
        #expect(reloaded.subtitleStyle.fontName == "Helvetica Neue")
        #expect(reloaded.subtitleStyle.fontSize == 24)
        #expect(reloaded.subtitleStyle.outlineColorARGB == 0xFFFFFFFF)
        #expect(reloaded.subtitleStyle.alignment == .topCenter)
        #expect(reloaded.subtitleStyle.marginVertical == 50)
        #expect(reloaded.subtitleStyle.marginHorizontal == 80)
    }

    @Test("Sequential field edits accumulate on disk (incremental autosave model)")
    func incrementalEditsAccumulateOnDisk() throws {
        // Simulates the autosave chain: user changes one field, ConfigService
        // calls `AppConfig.save`; user changes another, save runs again. The
        // file's final state must reflect both edits.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("config.json")
        let secrets = InMemorySecretStore()

        // Edit 1: baseURL
        var step = AppConfig()
        step.baseURL = "https://step1.example/v1"
        try step.save(to: filePath, secrets: secrets)

        // Edit 2: load, mutate apiKey, save
        step = try AppConfig.load(from: filePath, secrets: secrets)
        step.apiKey = "sk-step2-secret"
        try step.save(to: filePath, secrets: secrets)

        // Edit 3: load, mutate model + maxCharsPerBatch, save
        step = try AppConfig.load(from: filePath, secrets: secrets)
        step.model = "gpt-step3"
        step.maxCharsPerBatch = 9999
        try step.save(to: filePath, secrets: secrets)

        let final = try AppConfig.load(from: filePath, secrets: secrets)
        #expect(final.baseURL == "https://step1.example/v1", "step 1 edit lost")
        #expect(final.apiKey == "sk-step2-secret", "step 2 edit lost")
        #expect(final.model == "gpt-step3", "step 3 model edit lost")
        #expect(final.maxCharsPerBatch == 9999, "step 3 batch edit lost")
    }
}

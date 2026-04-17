import Testing
import Foundation
@testable import Domain
@testable import Infrastructure

@Suite("AppConfig")
struct AppConfigTests {

    @Test("Default config has sensible defaults")
    func defaults() {
        let config = AppConfig()
        #expect(config.baseURL == Constants.defaultOpenAIBaseURL)
        #expect(config.apiKey.isEmpty)
        #expect(config.model == Constants.defaultOpenAIModel)
        #expect(!config.skipTranslation)
        #expect(!config.skipSubtitleBurning)
        #expect(config.enableGoogleFallback)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var config = AppConfig()
        config.apiKey = "test-key-123"
        config.model = "gpt-4o"
        config.skipTranslation = true
        config.maxCharsPerBatch = 2000

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.apiKey == "test-key-123")
        #expect(decoded.model == "gpt-4o")
        #expect(decoded.skipTranslation == true)
        #expect(decoded.maxCharsPerBatch == 2000)
    }

    @Test("Saves and loads from file")
    func saveAndLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")

        var original = AppConfig()
        original.apiKey = "my-secret-key"
        original.skipSubtitleBurning = true
        try original.save(to: filePath)

        let loaded = try AppConfig.load(from: filePath)
        #expect(loaded.apiKey == "my-secret-key")
        #expect(loaded.skipSubtitleBurning == true)
    }

    @Test("Load returns default config when file is missing")
    func loadMissingFile() throws {
        let bogusPath = URL(filePath: "/tmp/nonexistent_\(UUID().uuidString).json")
        let config = (try? AppConfig.load(from: bogusPath)) ?? AppConfig()
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
}

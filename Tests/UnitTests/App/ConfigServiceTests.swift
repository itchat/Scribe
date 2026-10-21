import Testing
import Foundation
@testable import App
@testable import Domain
@testable import Infrastructure

/// `ConfigStoring` that keeps everything in memory, so these tests never
/// read or write the user's real config file or Keychain.
final class InMemoryConfigStore: ConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppConfig
    private(set) var saveCount = 0

    init(_ initial: AppConfig = AppConfig()) { stored = initial }

    var current: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func load() throws -> AppConfig { current }

    func save(_ config: AppConfig) throws {
        lock.lock(); defer { lock.unlock() }
        stored = config
        saveCount += 1
    }
}

/// Guards against editors overwriting each other's settings.
///
/// The Settings inspector and the Live Captions window each edit part of
/// the same `AppConfig`. Both used to write a whole config built from a copy
/// taken when they opened, so the last one to save reverted the other's
/// changes — including the API key, which `save` also pushes to the Keychain.
@MainActor
@Suite("ConfigService")
struct ConfigServiceTests {

    @Test("A Settings edit keeps an engine switch made after the inspector opened")
    func settingsEditKeepsLaterEngineSwitch() {
        let store = InMemoryConfigStore()
        let service = ConfigService(store: store)

        // Inspector opens and snapshots the config.
        let settings = SettingsViewModel(config: service.config)

        // Live Captions window switches engine afterwards.
        service.mutate { $0.liveCaptionEngine = .qwen3ASRLarge }

        // User then edits a field in the still-open inspector.
        settings.model = "gpt-edited"
        service.mutate { settings.apply(to: &$0) }

        #expect(service.config.model == "gpt-edited")
        #expect(service.config.liveCaptionEngine == .qwen3ASRLarge,
                "the inspector must not write back a field it doesn't edit")
        #expect(store.current.liveCaptionEngine == .qwen3ASRLarge)
    }

    @Test("An engine switch keeps an API key entered after the window opened")
    func engineSwitchKeepsLaterAPIKey() {
        let store = InMemoryConfigStore(AppConfig(apiKey: "sk-old"))
        let service = ConfigService(store: store)

        let settings = SettingsViewModel(config: service.config)
        settings.apiKey = "sk-new"
        service.mutate { settings.apply(to: &$0) }

        // The Live Captions window's change, in the shape it now uses.
        service.mutate { $0.liveCaptionEngine = .paraformerTrilingual }

        #expect(service.config.apiKey == "sk-new")
        #expect(store.current.apiKey == "sk-new",
                "the persisted key — and so the Keychain — must not be rolled back")
    }

    @Test("Applying Settings leaves fields that have no Settings control untouched")
    func applyLeavesUneditedFieldsAlone() {
        var config = AppConfig(maxRetries: 7, retryBaseDelay: 3.5, retryMaxDelay: 42)
        let settings = SettingsViewModel(config: config)
        settings.customPrompt = "edited"

        settings.apply(to: &config)

        #expect(config.customPrompt == "edited")
        #expect(config.maxRetries == 7)
        #expect(config.retryBaseDelay == 3.5)
        #expect(config.retryMaxDelay == 42)
    }

    @Test("mutate persists exactly once per call")
    func mutatePersists() {
        let store = InMemoryConfigStore()
        let service = ConfigService(store: store)

        service.mutate { $0.skipSubtitleBurning = true }

        #expect(store.saveCount == 1)
        #expect(store.current.skipSubtitleBurning == true)
    }

    @Test("A new service starts from what the store holds")
    func initLoadsFromStore() {
        let store = InMemoryConfigStore(AppConfig(offlineASREngine: .qwen3_0_6B))
        let service = ConfigService(store: store)

        #expect(service.config.offlineASREngine == .qwen3_0_6B)
    }
}

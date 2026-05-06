import SwiftUI
import Foundation
import Domain
import Infrastructure

/// Handles app configuration persistence.
///
/// SRP: Only loads, stores, and persists `AppConfig`.
@Observable
@MainActor
final class ConfigService {
    private(set) var config: AppConfig

    /// Initialise from disk by default so callers that read `config`
    /// synchronously at construction time (e.g. SwiftUI views creating
    /// `@State` objects in their body) see the user's persisted values
    /// instead of factory defaults. Pass an explicit `config:` for tests
    /// or DI scenarios that should bypass disk.
    init(config: AppConfig? = nil) {
        if let config {
            self.config = config
        } else {
            self.config = (try? AppConfig.load()) ?? AppConfig()
        }
    }

    /// Re-read from disk. Mostly redundant after `init` but kept for
    /// callers that want to refresh after an external edit.
    func load() {
        if let loaded = try? AppConfig.load() {
            self.config = loaded
        }
    }

    func update(_ newConfig: AppConfig) {
        self.config = newConfig
        try? newConfig.save()
    }
}

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

    init(config: AppConfig = AppConfig()) {
        self.config = config
    }

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

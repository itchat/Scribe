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

    /// Token for the `.resetSettings` subscription, released in `deinit`.
    ///
    /// `nonisolated(unsafe)` because `deinit` on a `@MainActor` type runs
    /// outside the actor and so cannot read isolated state. Safe here: the
    /// token is written exactly once during `init` and read exactly once
    /// during `deinit`, with no concurrent access in between. (The compiler
    /// suggests plain `nonisolated`, but that is rejected for mutable stored
    /// properties — the suggestion comes from the `@Observable` expansion.)
    private nonisolated(unsafe) var resetObserver: (any NSObjectProtocol)?

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

        // "Reset Settings to Defaults…" posts `.resetSettings` from the app
        // menu. Its only subscriber used to be `SettingsInspector`, a view
        // that exists solely while the inspector is presented — so with the
        // inspector closed the user got the confirmation alert and then
        // nothing at all. Owning the subscription here makes the reset work
        // regardless of what is on screen.
        resetObserver = NotificationCenter.default.addObserver(
            forName: .resetSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetToDefaults()
            }
        }
    }

    deinit {
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    /// Restore factory defaults and persist them.
    func resetToDefaults() {
        update(AppConfig())
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

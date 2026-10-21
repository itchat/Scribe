import SwiftUI
import Foundation
import Domain
import Infrastructure

/// Handles app configuration persistence.
///
/// SRP: Only loads, stores, and persists `AppConfig`.
/// DIP: persistence goes through `ConfigStoring`, so tests run against an
/// in-memory store instead of the user's real file and Keychain.
///
/// There must be exactly one instance per process — `ScribeApp` creates it
/// and hands it to every window. Each window used to build its own, and
/// because `update` writes the *whole* config, whichever window saved last
/// replaced the other's changes with its stale snapshot, API key included.
@Observable
@MainActor
final class ConfigService {
    private(set) var config: AppConfig

    private let store: any ConfigStoring

    /// Token for the `.resetSettings` subscription, released in `deinit`.
    ///
    /// `nonisolated(unsafe)` because `deinit` on a `@MainActor` type runs
    /// outside the actor and so cannot read isolated state. Safe here: the
    /// token is written exactly once during `init` and read exactly once
    /// during `deinit`, with no concurrent access in between. (The compiler
    /// suggests plain `nonisolated`, but that is rejected for mutable stored
    /// properties — the suggestion comes from the `@Observable` expansion.)
    private nonisolated(unsafe) var resetObserver: (any NSObjectProtocol)?

    /// Initialise from the store so callers that read `config`
    /// synchronously at construction time (e.g. SwiftUI views creating
    /// `@State` objects in their body) see the user's persisted values
    /// instead of factory defaults.
    init(store: any ConfigStoring = FileConfigStore()) {
        self.store = store
        self.config = (try? store.load()) ?? AppConfig()

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

    /// Re-read from the store, for callers that want to pick up an
    /// external edit.
    func load() {
        if let loaded = try? store.load() {
            self.config = loaded
        }
    }

    /// Change only the fields `change` touches, starting from the current
    /// config, and persist the result.
    ///
    /// Prefer this over `update(_:)` from any editor that owns a subset of
    /// the settings. Building a full `AppConfig` from a copy taken earlier
    /// writes every field the editor doesn't own back at its old value.
    func mutate(_ change: (inout AppConfig) -> Void) {
        var next = config
        change(&next)
        update(next)
    }

    /// Replace the whole config. Only for callers that really mean every
    /// field, such as a reset.
    func update(_ newConfig: AppConfig) {
        self.config = newConfig
        try? store.save(newConfig)
    }
}

import Foundation

/// Loads and saves the whole `AppConfig`.
///
/// SOLID:
/// - **DIP**: `ConfigService` depends on this protocol, not on the file
///   system or the Keychain, so it can be exercised against an in-memory
///   store without touching the user's real settings.
/// - **ISP**: two calls — everything else about the config (validation,
///   migration, encoding) stays on `AppConfig` itself.
public protocol ConfigStoring: Sendable {
    func load() throws -> AppConfig
    func save(_ config: AppConfig) throws
}

/// Production `ConfigStoring`: the JSON file under Application Support plus
/// the Keychain for the API key, exactly as `AppConfig.save` / `.load` do.
///
/// SRP: only forwards to `AppConfig`'s own persistence with fixed locations.
public struct FileConfigStore: ConfigStoring {
    private let fileURL: URL?
    private let secrets: any SecretStoring

    public init(fileURL: URL? = nil, secrets: any SecretStoring = KeychainSecretStore()) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public func load() throws -> AppConfig {
        try AppConfig.load(from: fileURL, secrets: secrets)
    }

    public func save(_ config: AppConfig) throws {
        try config.save(to: fileURL, secrets: secrets)
    }
}

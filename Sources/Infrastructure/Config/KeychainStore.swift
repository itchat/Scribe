import Foundation
import Security
import os

/// Stores the OpenAI API key in the login Keychain.
///
/// SOLID:
/// - **SRP**: only reads, writes and deletes one secret. It knows nothing
///   about `AppConfig` or translation.
///
/// The key previously lived in plaintext in
/// `~/Library/Application Support/Scribe/config.json`, written with
/// `Data.write(options: .atomic)` — which sets no POSIX mode, so the file
/// landed at the umask default (0644) and was readable by every local user
/// and every unsandboxed process running as the user. The UI already used a
/// `SecureField`, which made the on-disk plaintext more surprising, not less.
/// Abstraction over secret storage.
///
/// DIP: `AppConfig` persists through this rather than reaching for the
/// Keychain directly, so tests run against an in-memory double instead of
/// touching (or being blocked by) the real login keychain.
public protocol SecretStoring: Sendable {
    func readAPIKey() -> String?
    @discardableResult func writeAPIKey(_ key: String) -> Bool
}

/// Production `SecretStoring`, backed by the login Keychain.
public struct KeychainSecretStore: SecretStoring {
    public init() {}
    public func readAPIKey() -> String? { KeychainStore.readAPIKey() }
    @discardableResult public func writeAPIKey(_ key: String) -> Bool { KeychainStore.writeAPIKey(key) }
}

public enum KeychainStore {

    private static let logger = Logger(subsystem: "com.scribe", category: "keychain")
    private static let service = "com.scribe.openai"
    private static let account = "apiKey"

    /// Read the stored key, or nil when absent or unreadable.
    public static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                logger.error("Keychain read failed (OSStatus \(status, privacy: .public))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store the key, replacing any existing value. An empty string deletes.
    @discardableResult
    public static func writeAPIKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return deleteAPIKey() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            // The key is only needed while the user is driving the app, so
            // it does not need to be available before first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                logger.error("Keychain add failed (OSStatus \(addStatus, privacy: .public))")
            }
            return addStatus == errSecSuccess
        }

        logger.error("Keychain update failed (OSStatus \(updateStatus, privacy: .public))")
        return false
    }

    @discardableResult
    public static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

import Foundation
import Security

/// Registry credentials persisted in the macOS Keychain — never in the repo,
/// never in a plaintext config. The password lives only here at rest.
struct RegistryCredentials: Codable, Sendable, Hashable {
    let username: String
    let password: String
}

/// Thin wrapper over the Keychain (generic password items) scoped to this app.
enum KeychainStore {
    /// Service attribute scoping all items to Irekobox's registry logins.
    private static let service = "com.irekobox.registry"

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    /// Save (or replace) credentials for `server`.
    static func save(server: String, credentials: RegistryCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        delete(server: server)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Load credentials for `server`, if any.
    static func load(server: String) -> RegistryCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(RegistryCredentials.self, from: data)
    }

    /// Delete credentials for `server` (no-op if absent).
    static func delete(server: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// All servers with saved credentials.
    static func savedServers() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

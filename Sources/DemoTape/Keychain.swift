import Foundation
import Security

/// Minimal Keychain wrapper for storing BYO-key API secrets.
///
/// API keys are never written to UserDefaults or disk in the clear — they live in
/// the login keychain under DemoTape's service, and are only read when the user has
/// explicitly enabled an AI feature.
enum Keychain {
    private static let service = "dev.demotape.app"

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Prefer an in-place update — reliably overwrites an existing item (delete-then-add
        // can leave a stale value if the item was created by a different code signature and
        // the delete is denied).
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update == errSecItemNotFound {
            var attrs = base
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
        }
        // Update failed for another reason — fall back to delete + add.
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let add = SecItemAdd(attrs as CFDictionary, nil)
        if add == errSecDuplicateItem {
            return SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return add == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    /// Whether an item exists WITHOUT reading its secret data. This avoids the macOS keychain
    /// access prompt that `get` triggers when the app's signature has changed (common across
    /// local rebuilds). Use for UI gating; use `get` only when the secret is actually needed.
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,           // don't decrypt → no ACL prompt
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // Account keys used by the app.
    static let sttAPIKeyAccount = "stt-api-key"
    static let elevenAPIKeyAccount = "elevenlabs-api-key"
    static let heygenAPIKeyAccount = "heygen-api-key"
}

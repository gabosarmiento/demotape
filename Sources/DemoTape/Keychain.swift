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
        // Replace any existing item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
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

import Foundation
import Security

/// Minimal Keychain wrapper for the session bearer token. Unlike Lumisound's
/// single shared "apiKey" (fine for a personal single-owner tool, kept in
/// UserDefaults), Nyxframe has real per-user login/password accounts, so
/// the session token gets Keychain storage instead — see the iOS plan's notes.
enum KeychainHelper {
    private static let service = "com.imagegallery.ios.session"

    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        var query = baseQuery(forKey: key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(forKey key: String) {
        let query = baseQuery(forKey: key)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

import Foundation
import Security

/// Minimal generic-password Keychain wrapper for small secrets such as the
/// optional Yelp key. Values are device-only and readable after first unlock.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.gabrielconlon.CustomMapApp") + ".secrets") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored string, or nil when absent or unreadable.
    func string(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`; nil or empty deletes. Returns whether it succeeded.
    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(account) }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the item. Deleting something absent counts as success.
    @discardableResult
    func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

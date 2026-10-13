import Foundation
import Security

enum KeychainStore {
    private static let service = "com.konrad.agentapp.backends"
    static func set(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var insert = query; insert[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(insert as CFDictionary, nil)
    }
    static func get(account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    /// Whether an item exists, from its attributes only, so no access prompt can appear.
    static func exists(account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func accounts(prefix: String) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
}

/// Where Hermes API keys live. The app uses the Keychain; tests inject an in-memory store.
protocol HermesKeyStore: Sendable {
    func key(for account: String) -> String
    func setKey(_ value: String, for account: String)
    func hasKey(for account: String) -> Bool
}

extension HermesKeyStore {
    func hasKey(for account: String) -> Bool { !key(for: account).isEmpty }
}

struct KeychainHermesKeyStore: HermesKeyStore {
    func key(for account: String) -> String { KeychainStore.get(account: account) }
    func setKey(_ value: String, for account: String) { KeychainStore.set(value, account: account) }
    func hasKey(for account: String) -> Bool { KeychainStore.exists(account: account) }
}

import Foundation
import Security

struct KeychainCredentials {
    private let service = "com.konrad.swarmhub.ios.backends"
    func read(_ account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return value
    }
    func write(_ key: String, account: String) throws {
        let attributes: [CFString: Any] = [kSecValueData: Data(key.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base(account); attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if status != errSecSuccess { throw CredentialError.unavailable }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
    }
    private func base(_ account: String) -> [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] }
}
enum CredentialError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The iPhone Keychain is unavailable. The connection was not saved." }
}

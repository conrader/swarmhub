import Foundation
import Security

/// Supplies the *Grok Bot Safe Storage* password bytes. The live implementation raises the one macOS
/// Keychain Allow dialog; tests inject a fake so nothing reaches the real Keychain.
protocol GrokPasswordProvider: Sendable {
    /// An attributes-only probe: does the item exist, and does a metadata query return without a dialog?
    /// Returns the OSStatus; the caller times it (500 ms or more suggests a dialog blocked it).
    func probe() -> OSStatus
    /// The one data read. May block on the macOS dialog. The caller zeroes the returned bytes.
    func readPassword() throws -> [UInt8]
}

enum GrokKeychainError: Error, Equatable, CustomStringConvertible {
    case denied(OSStatus)
    case itemMissing
    case keychainLocked
    case interactionNotAllowed
    case unexpected(OSStatus)

    var description: String {
        switch self {
        case .denied(let status): return "Keychain read was denied (OSStatus \(status))"
        case .itemMissing: return "the Grok Bot Safe Storage item is not in the Keychain"
        case .keychainLocked: return "the login keychain is locked"
        case .interactionNotAllowed: return "the Keychain cannot prompt in this context"
        case .unexpected(let status): return "Keychain read failed (OSStatus \(status))"
        }
    }

    /// Maps the OSStatus a `SecItemCopyMatching` returns to a specific error.
    static func from(_ status: OSStatus) -> GrokKeychainError {
        switch status {
        case errSecItemNotFound: return .itemMissing
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled: return .denied(status)
        case -25308: return .keychainLocked // errSecInteractionRequired / locked keychain
        default: return .unexpected(status)
        }
    }
}

/// Reads the generic-password item `service="Grok Bot Safe Storage", account="Grok Bot Key"` from the app's
/// own process (never `/usr/bin/security`). The read runs on a private queue bridged by a continuation, so it
/// is off the main actor and the cooperative pool while the dialog is up (Rule 3). Callers gate it behind the
/// in-flight flag and the cheap checks.
struct GrokKeychain: GrokPasswordProvider {
    static let queue = DispatchQueue(label: "com.konrad.agentapp.grok-keychain")

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: GrokProtocol.keychainService,
         kSecAttrAccount as String: GrokProtocol.keychainAccount]
    }

    func probe() -> OSStatus {
        if TestRunGuard.refuses("Keychain probe Grok Bot Safe Storage") { return errSecInteractionNotAllowed }
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return KeychainAccess.shared.exclusive {
            var result: CFTypeRef?
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
    }

    func readPassword() throws -> [UInt8] {
        if TestRunGuard.refuses("Keychain read Grok Bot Safe Storage") { throw GrokKeychainError.interactionNotAllowed }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Under the app's Keychain lock, so no silent key read can disable interaction while this dialog is up.
        let (status, result) = KeychainAccess.shared.exclusive { () -> (OSStatus, CFTypeRef?) in
            var result: CFTypeRef?
            return (SecItemCopyMatching(query as CFDictionary, &result), result)
        }
        guard status == errSecSuccess else { throw GrokKeychainError.from(status) }
        guard let data = result as? Data else { throw GrokKeychainError.unexpected(errSecInternalError) }
        return [UInt8](data)
    }
}

import CryptoKit
import Foundation
import Security

/// Approval-only storage. No migration, fallback, or lookup in the Hermes/OpenClaw vault.
protocol DeviceApprovalKeyStore: Sendable {
    func read(account: String) throws -> Data?
    func insert(_ seed: Data, account: String) throws
}

struct ApprovalKeychainStore: DeviceApprovalKeyStore {
    static let service = "com.swarmhub.device-approvals.v2"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func read(account: String) throws -> Data? {
        guard !TestRunGuard.refuses("approval Keychain read") else { throw DeviceApprovalIdentity.Failure.storage }
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceApprovalIdentity.Failure.storage }
        return data
    }

    func insert(_ seed: Data, account: String) throws {
        guard !TestRunGuard.refuses("approval Keychain write") else { throw DeviceApprovalIdentity.Failure.storage }
        var query = query(account)
        query[kSecValueData as String] = seed
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Insert only: a duplicate or inaccessible item must never silently rotate an enrolled identity.
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw DeviceApprovalIdentity.Failure.storage }
    }
}

/// One new Ed25519 key per Mac/box pair. Private bytes never appear in mirrors or descriptions.
struct DeviceApprovalIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let keyID: String
    let publicKey: String
    private let seed: Data

    enum Failure: LocalizedError { case storage, unreadableKey
        var errorDescription: String? {
            switch self {
            case .storage: "The approval key could not be saved and read back in Keychain. Nothing was sent."
            case .unreadableKey: "The stored approval key is unreadable. Resolve it locally before enrolling a replacement."
            }
        }
    }

    init(seed: Data, keyID: String? = nil) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.seed = seed
        publicKey = DeviceApprovalWire.hex(key.publicKey.rawRepresentation)
        self.keyID = keyID ?? "mac-" + String(DeviceApprovalWire.digest(key.publicKey.rawRepresentation).prefix(48))
    }

    static func account(box: String) -> String { "approval-v2." + DeviceApprovalWire.digest(Data(box.utf8)) }

    static func loadOrCreate(box: String, store: any DeviceApprovalKeyStore) throws -> Self {
        let account = account(box: box)
        if let seed = try store.read(account: account) {
            guard seed.count == 32, let identity = try? Self(seed: seed) else { throw Failure.unreadableKey }
            return identity
        }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        try store.insert(seed, account: account)
        guard try store.read(account: account) == seed else { throw Failure.storage }
        return try Self(seed: seed)
    }

    func signature(for message: Data) throws -> String {
        DeviceApprovalWire.hex(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message))
    }

    var description: String { "DeviceApprovalIdentity(keyID: \(keyID))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["keyID": keyID, "publicKey": publicKey]) }
}

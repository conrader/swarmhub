import CryptoKit
import Foundation
import Security

/// Approval-only storage. No migration, fallback, or lookup in the Hermes/OpenClaw vault.
public protocol DeviceApprovalKeyStore: Sendable {
    func read(account: String) throws -> Data?
    func insert(_ seed: Data, account: String) throws
}

/// This device's approval Keychain items: never synchronized, readable only while unlocked on this device.
/// `refuses` lets a host app block access during test or QA runs (the Mac passes its TestRunGuard).
public struct DeviceApprovalKeychain: DeviceApprovalKeyStore {
    public static let service = "com.swarmhub.device-approvals.v2"
    private let refuses: @Sendable (String) -> Bool

    public init(refuses: @escaping @Sendable (String) -> Bool = { _ in false }) { self.refuses = refuses }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    public func read(account: String) throws -> Data? {
        guard !refuses("approval Keychain read") else { throw DeviceApprovalIdentity.Failure.storage }
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DeviceApprovalIdentity.Failure.storage }
        return data
    }

    public func insert(_ seed: Data, account: String) throws {
        guard !refuses("approval Keychain write") else { throw DeviceApprovalIdentity.Failure.storage }
        var query = query(account)
        query[kSecValueData as String] = seed
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Insert only: a duplicate or inaccessible item must never silently rotate an enrolled identity.
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw DeviceApprovalIdentity.Failure.storage }
    }
}

/// One new Ed25519 key per device/box pair. Private bytes never appear in mirrors or descriptions.
public struct DeviceApprovalIdentity: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Key IDs default to the Mac prefix, so existing Mac identities keep their IDs. iOS passes `iosKeyPrefix`.
    public static let macKeyPrefix = "mac-"
    public static let iosKeyPrefix = "ios-"
    public let keyID: String
    public let publicKey: String
    private let seed: Data

    public enum Failure: LocalizedError { case storage, unreadableKey
        public var errorDescription: String? {
            switch self {
            case .storage: "The approval key could not be saved and read back in Keychain. Nothing was sent."
            case .unreadableKey: "The stored approval key is unreadable. Resolve it locally before enrolling a replacement."
            }
        }
    }

    public init(seed: Data, keyID: String? = nil, prefix: String = DeviceApprovalIdentity.macKeyPrefix) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.seed = seed
        publicKey = DeviceApprovalWire.hex(key.publicKey.rawRepresentation)
        self.keyID = keyID ?? prefix + String(DeviceApprovalWire.digest(key.publicKey.rawRepresentation).prefix(48))
    }

    public static func account(box: String) -> String { "approval-v2." + DeviceApprovalWire.digest(Data(box.utf8)) }

    public static func loadOrCreate(box: String, store: any DeviceApprovalKeyStore, prefix: String = DeviceApprovalIdentity.macKeyPrefix) throws -> Self {
        let account = account(box: box)
        if let seed = try store.read(account: account) {
            guard seed.count == 32, let identity = try? Self(seed: seed, prefix: prefix) else { throw Failure.unreadableKey }
            return identity
        }
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        try store.insert(seed, account: account)
        guard try store.read(account: account) == seed else { throw Failure.storage }
        return try Self(seed: seed, prefix: prefix)
    }

    public func signature(for message: Data) throws -> String {
        DeviceApprovalWire.hex(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message))
    }

    public var description: String { "DeviceApprovalIdentity(keyID: \(keyID))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["keyID": keyID, "publicKey": publicKey]) }
}

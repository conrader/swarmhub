import Foundation
import Security

/// The one serialized lock for every Keychain call the app makes. SwarmHub's own key calls run inside it with user
/// interaction disabled (`SecKeychainSetUserInteractionAllowed(false)`, restored before the lock is released), so they can
/// never raise a dialog; the Grok *Safe Storage* read takes the same lock without changing the flag, so its one intended
/// Allow prompt is never suppressed by a key read running at the same time (the flag is process-wide).
final class KeychainAccess: @unchecked Sendable {
    static let shared = KeychainAccess(
        isAllowed: { var allowed: DarwinBoolean = true; _ = SecKeychainGetUserInteractionAllowed(&allowed); return allowed.boolValue },
        setAllowed: { _ = SecKeychainSetUserInteractionAllowed($0) })

    private let lock = NSLock()
    private let isAllowed: @Sendable () -> Bool
    private let setAllowed: @Sendable (Bool) -> Void

    init(isAllowed: @escaping @Sendable () -> Bool, setAllowed: @escaping @Sendable (Bool) -> Void) {
        self.isAllowed = isAllowed; self.setAllowed = setAllowed
    }

    /// Runs `body` with user interaction disabled; a call that would need a dialog fails with `errSecInteractionNotAllowed`.
    func silently<T>(_ body: () -> T) -> T {
        lock.withLock {
            let previous = isAllowed()
            setAllowed(false)
            defer { setAllowed(previous) }
            return body()
        }
    }

    /// Runs `body` under the lock with the flag untouched (the Grok read and its attributes probe).
    func exclusive<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }
}

/// The raw Keychain calls for SwarmHub's generic-password items. Tests inject a fake.
protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> (status: OSStatus, value: String?)
    func add(_ value: String, service: String, account: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
    /// From attributes only, so no access prompt can appear.
    func exists(service: String, account: String) -> Bool
    /// From attributes only, so no access prompt can appear.
    func allAccounts(service: String) -> [String]
}

/// The live Keychain: every call goes through `KeychainAccess.silently`.
struct SecKeychainBackend: KeychainBackend {
    var access: KeychainAccess = .shared

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) -> (status: OSStatus, value: String?) {
        var query = query(service, account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        return access.silently {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { return (status == errSecSuccess ? errSecInternalError : status, nil) }
            return (status, String(decoding: data, as: UTF8.self))
        }
    }
    func add(_ value: String, service: String, account: String) -> OSStatus {
        var insert = query(service, account); insert[kSecValueData as String] = Data(value.utf8)
        return access.silently { SecItemAdd(insert as CFDictionary, nil) }
    }
    func delete(service: String, account: String) -> OSStatus {
        let query = query(service, account)
        return access.silently { SecItemDelete(query as CFDictionary) }
    }
    func exists(service: String, account: String) -> Bool {
        var query = query(service, account); query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        return access.silently { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }
    }
    func allAccounts(service: String) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        return access.silently {
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
            return rows.compactMap { $0[kSecAttrAccount as String] as? String }
        }
    }
}

/// Stands in for the Keychain in test runs: nothing is stored outside the cache and no call can prompt.
struct DetachedKeychainBackend: KeychainBackend {
    func read(service: String, account: String) -> (status: OSStatus, value: String?) { (errSecItemNotFound, nil) }
    func add(_ value: String, service: String, account: String) -> OSStatus { errSecSuccess }
    func delete(service: String, account: String) -> OSStatus { errSecItemNotFound }
    func exists(service: String, account: String) -> Bool { false }
    func allAccounts(service: String) -> [String] { [] }
}

/// SwarmHub's API keys. Each account resolves once per launch: memory cache -> v2 item (`com.konrad.agentapp.keys.v2`,
/// written by this app) -> legacy item (`com.konrad.agentapp.backends`, read silently; a key that reads fine is copied to
/// v2). A legacy item that would need a dialog, or fails, leaves the account "needs re-entry" for the launch: no retry,
/// no dialog. `AppStore.recoverLockedKeys` may then derive the key (P22). Legacy items are never written or deleted.
final class KeyVault: @unchecked Sendable {
    static let legacyService = "com.konrad.agentapp.backends"
    static let v2Service = "com.konrad.agentapp.keys.v2"
    static let clearedKey = "keysV2.cleared"

    /// Test runs never touch the real Keychain; only the bundled app copies legacy keys into v2.
    static let shared = isTestRun
        ? KeyVault(backend: DetachedKeychainBackend(), defaults: UserDefaults(suiteName: "AgentAppTests-KeyVault") ?? .standard, copiesLegacy: false)
        : KeyVault(backend: SecKeychainBackend(), defaults: .standard, copiesLegacy: Bundle.main.bundleURL.pathExtension == "app")
    static var isTestRun: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil || ["xctest", "swiftpm-testing-helper"].contains(ProcessInfo.processInfo.processName)
    }

    private let lock = NSLock()
    private let backend: any KeychainBackend
    private let defaults: UserDefaults
    private let copiesLegacy: Bool
    private var values: [String: String] = [:]
    private var locked: Set<String> = []
    private var recoveryClaimed: Set<String> = []

    init(backend: any KeychainBackend, defaults: UserDefaults, copiesLegacy: Bool = true) {
        self.backend = backend; self.defaults = defaults; self.copiesLegacy = copiesLegacy
    }

    func get(account: String) -> String {
        lock.withLock {
            if let value = values[account] { return value }
            if locked.contains(account) { return "" }
            guard let value = resolve(account) else { locked.insert(account); return "" }
            values[account] = value
            return value
        }
    }

    /// Updates the cache and the v2 item. An empty value deletes the v2 item and is remembered, so the legacy item is
    /// not read again on later launches.
    func set(_ value: String, account: String) {
        lock.withLock {
            let wasLocked = locked.remove(account) != nil
            if values[account] == value, !wasLocked { return }
            values[account] = value
            _ = backend.delete(service: Self.v2Service, account: account)
            var cleared = Set(defaults.stringArray(forKey: Self.clearedKey) ?? [])
            if value.isEmpty { cleared.insert(account) } else {
                cleared.remove(account)
                _ = backend.add(value, service: Self.v2Service, account: account)
            }
            defaults.set(cleared.sorted(), forKey: Self.clearedKey)
        }
    }

    /// The legacy item would need a dialog (or failed) and no key replaced it this launch.
    func needsReentry(account: String) -> Bool { lock.withLock { locked.contains(account) } }

    /// True once per account per launch: the one derived-key attempt.
    func claimRecovery(account: String) -> Bool { lock.withLock { recoveryClaimed.insert(account).inserted } }

    /// From the cache or item attributes only, so no access prompt can appear.
    func exists(account: String) -> Bool {
        if let value = lock.withLock({ values[account] }) { return !value.isEmpty }
        if backend.exists(service: Self.v2Service, account: account) { return true }
        return !isCleared(account) && backend.exists(service: Self.legacyService, account: account)
    }

    func accounts(prefix: String) -> [String] {
        let legacy = backend.allAccounts(service: Self.legacyService).filter { !isCleared($0) }
        return Set(backend.allAccounts(service: Self.v2Service) + legacy).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func isCleared(_ account: String) -> Bool { (defaults.stringArray(forKey: Self.clearedKey) ?? []).contains(account) }

    /// nil = needs re-entry; "" = no key anywhere.
    private func resolve(_ account: String) -> String? {
        let (v2Status, v2Value) = backend.read(service: Self.v2Service, account: account)
        if v2Status == errSecSuccess, let v2Value { return v2Value }
        if isCleared(account) { return "" }
        let (status, value) = backend.read(service: Self.legacyService, account: account)
        if status == errSecSuccess, let value {
            if copiesLegacy {
                if v2Status != errSecItemNotFound { _ = backend.delete(service: Self.v2Service, account: account) }
                _ = backend.add(value, service: Self.v2Service, account: account)
            }
            return value
        }
        if status == errSecItemNotFound, v2Status == errSecItemNotFound { return "" }
        return nil
    }
}

enum KeychainStore {
    static let reenterMessage = "Re-enter this bot's key"
    static func set(_ value: String, account: String) { KeyVault.shared.set(value, account: account) }
    static func get(account: String) -> String { KeyVault.shared.get(account: account) }
    /// Whether a key exists, from the cache or item attributes only, so no access prompt can appear.
    static func exists(account: String) -> Bool { KeyVault.shared.exists(account: account) }
    static func accounts(prefix: String) -> [String] { KeyVault.shared.accounts(prefix: prefix) }
}

/// Where Hermes API keys live. The app uses the Keychain; tests inject an in-memory store.
protocol HermesKeyStore: Sendable {
    func key(for account: String) -> String
    func setKey(_ value: String, for account: String)
    func hasKey(for account: String) -> Bool
    /// True when the stored key could not be read without a dialog and nothing replaced it; callers show
    /// `KeychainStore.reenterMessage`.
    func needsReentry(_ account: String) -> Bool
    /// True once per account per launch: whether this caller may make the one derived-key attempt.
    func claimRecovery(_ account: String) -> Bool
}

extension HermesKeyStore {
    func hasKey(for account: String) -> Bool { !key(for: account).isEmpty }
    func needsReentry(_ account: String) -> Bool { false }
    func claimRecovery(_ account: String) -> Bool { false }
}

struct KeychainHermesKeyStore: HermesKeyStore {
    var vault: KeyVault = .shared
    func key(for account: String) -> String { vault.get(account: account) }
    func setKey(_ value: String, for account: String) { vault.set(value, account: account) }
    func hasKey(for account: String) -> Bool { vault.exists(account: account) }
    func needsReentry(_ account: String) -> Bool { vault.needsReentry(account: account) }
    func claimRecovery(_ account: String) -> Bool { vault.claimRecovery(account: account) }
}

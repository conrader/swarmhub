import Foundation
import Security
import Testing
@testable import AgentApp

// 0.4.3 key storage: SwarmHub never shows a Keychain dialog for its own keys. Fake Keychain and synthetic servers only;
// nothing here reaches the real Keychain.

private let legacy = KeyVault.legacyService
private let v2 = KeyVault.v2Service

/// Fake Keychain keyed by service and account: counts every call, answers reads with a fixed status where told to,
/// and tracks how many reads overlap.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    struct Call: Equatable { let op: String; let service: String; let account: String }
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var readStatus: [String: OSStatus] = [:]
    private var inFlight = 0
    var addStatus: OSStatus = errSecSuccess
    var readDelay: TimeInterval = 0
    private(set) var calls: [Call] = []
    private(set) var maxParallelReads = 0

    init(legacy: [String: String] = [:], v2: [String: String] = [:]) {
        for (account, value) in legacy { items["\(KeyVault.legacyService)|\(account)"] = value }
        for (account, value) in v2 { items["\(KeyVault.v2Service)|\(account)"] = value }
    }
    /// The status a dialog-gated item gives with interaction disabled.
    func answer(_ service: String, _ account: String, with status: OSStatus) { lock.withLock { readStatus["\(service)|\(account)"] = status } }
    func stored(_ service: String, _ account: String) -> String? { lock.withLock { items["\(service)|\(account)"] } }
    func calls(_ op: String, _ service: String? = nil) -> [String] {
        lock.withLock { calls.filter { $0.op == op && (service == nil || $0.service == service) }.map(\.account) }
    }

    func read(service: String, account: String) -> (status: OSStatus, value: String?) {
        lock.withLock { calls.append(.init(op: "read", service: service, account: account)); inFlight += 1; maxParallelReads = max(maxParallelReads, inFlight) }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        return lock.withLock {
            inFlight -= 1
            if let status = readStatus["\(service)|\(account)"] { return (status, nil) }
            guard let value = items["\(service)|\(account)"] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, value)
        }
    }
    func add(_ value: String, service: String, account: String) -> OSStatus {
        lock.withLock {
            calls.append(.init(op: "add", service: service, account: account))
            guard addStatus == errSecSuccess else { return addStatus }
            guard items["\(service)|\(account)"] == nil else { return errSecDuplicateItem }
            items["\(service)|\(account)"] = value; return errSecSuccess
        }
    }
    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            calls.append(.init(op: "delete", service: service, account: account))
            return items.removeValue(forKey: "\(service)|\(account)") == nil ? errSecItemNotFound : errSecSuccess
        }
    }
    func exists(service: String, account: String) -> Bool {
        lock.withLock { calls.append(.init(op: "attributes", service: service, account: account)); return items["\(service)|\(account)"] != nil }
    }
    func allAccounts(service: String) -> [String] {
        lock.withLock {
            calls.append(.init(op: "attributes", service: service, account: "*"))
            return items.keys.filter { $0.hasPrefix(service + "|") }.map { String($0.dropFirst(service.count + 1)) }
        }
    }
    /// Legacy items must never be written or deleted.
    var legacyWrites: [String] { lock.withLock { calls.filter { $0.service == KeyVault.legacyService && ($0.op == "add" || $0.op == "delete") }.map(\.account) } }
}

private func vault(_ fake: FakeKeychain, defaults: UserDefaults = isolatedDefaults()) -> KeyVault {
    KeyVault(backend: fake, defaults: defaults)
}

// MARK: Rule 1: every call runs with interaction disabled, inside the lock the Grok read also takes

@Test func silentKeychainCallsDisableInteractionAndRestoreIt() {
    let flag = LockedFlag(true)
    let access = KeychainAccess(isAllowed: { flag.value }, setAllowed: { flag.value = $0 })
    let seen = access.silently { flag.value }
    #expect(seen == false && flag.value == true)
    flag.value = false
    _ = access.silently { 0 }
    #expect(flag.value == false)
}

@Test func grokReadAndSilentReadsShareOneLock() {
    let flag = LockedFlag(true); let trace = LockedTrace()
    let access = KeychainAccess(isAllowed: { flag.value }, setAllowed: { flag.value = $0 })
    let grokHolding = DispatchSemaphore(value: 0); let done = DispatchGroup()
    DispatchQueue.global().async(group: done) {
        access.exclusive {
            grokHolding.signal()
            Thread.sleep(forTimeInterval: 0.15)
            trace.add("grok-done allowed=\(flag.value)")
        }
    }
    grokHolding.wait()
    DispatchQueue.global().async(group: done) { access.silently { trace.add("key-read allowed=\(flag.value)") } }
    done.wait()
    #expect(trace.read() == ["grok-done allowed=true", "key-read allowed=false"])
    #expect(flag.value == true)
}

// MARK: Rule 2: read order memory -> v2 -> legacy (silent) -> needs re-entry

@Test func keyReadsV2FirstAndNeverTouchesLegacyWhenV2Has() {
    let fake = FakeKeychain(legacy: ["herdr.grok-dmt": "old"], v2: ["herdr.grok-dmt": "new"])
    #expect(vault(fake).get(account: "herdr.grok-dmt") == "new")
    #expect(fake.calls("read") == ["herdr.grok-dmt"] && fake.calls("read", legacy).isEmpty)
}

@Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecIO])
func legacyItemThatNeedsADialogOrFailsLeavesTheKeyNeedingReentry(status: OSStatus) {
    let fake = FakeKeychain(legacy: ["herdr.grok-dmt": "old"]); fake.answer(legacy, "herdr.grok-dmt", with: status)
    let keys = vault(fake)
    for _ in 0..<10 { #expect(keys.get(account: "herdr.grok-dmt") == "") }
    #expect(keys.needsReentry(account: "herdr.grok-dmt") && keys.exists(account: "herdr.grok-dmt"))
    #expect(fake.calls("read", legacy).count == 1 && fake.calls("read", v2).count == 1)
    #expect(fake.calls("add").isEmpty && fake.legacyWrites.isEmpty && fake.stored(legacy, "herdr.grok-dmt") == "old")
}

@Test func missingKeyIsNotReentry() {
    let fake = FakeKeychain(); let keys = vault(fake)
    #expect(keys.get(account: "herdr.none") == "" && !keys.needsReentry(account: "herdr.none") && !keys.exists(account: "herdr.none"))
}

@Test func unreadableV2WithNoLegacyNeedsReentry() {
    let fake = FakeKeychain(v2: ["herdr.x": "v"]); fake.answer(v2, "herdr.x", with: errSecInteractionNotAllowed)
    let keys = vault(fake)
    #expect(keys.get(account: "herdr.x") == "" && keys.needsReentry(account: "herdr.x"))
}

// MARK: Rule 3: a legacy item that reads fine is copied to v2; legacy items are never deleted

@Test func readableLegacyKeyIsCopiedToV2AndLegacyIsKept() {
    let fake = FakeKeychain(legacy: ["herdr.grok-jarvis": "jk"]); let defaults = isolatedDefaults()
    #expect(vault(fake, defaults: defaults).get(account: "herdr.grok-jarvis") == "jk")
    #expect(fake.stored(v2, "herdr.grok-jarvis") == "jk" && fake.stored(legacy, "herdr.grok-jarvis") == "jk" && fake.legacyWrites.isEmpty)
    // Next launch reads v2 only.
    #expect(vault(fake, defaults: defaults).get(account: "herdr.grok-jarvis") == "jk")
    #expect(fake.calls("read", legacy).count == 1 && fake.calls("read", v2).count == 2 && fake.calls("add").count == 1)
}

@Test func onlyCopyingVaultsWriteV2OnRead() {
    let fake = FakeKeychain(legacy: ["herdr": "k"])
    #expect(KeyVault(backend: fake, defaults: isolatedDefaults(), copiesLegacy: false).get(account: "herdr") == "k")
    #expect(fake.calls("add").isEmpty && fake.calls("delete").isEmpty)
}

@Test func failedV2CopyStillServesTheKeyWithoutRetry() {
    let fake = FakeKeychain(legacy: ["herdr": "k"]); fake.addStatus = errSecIO; let keys = vault(fake)
    for _ in 0..<5 { #expect(keys.get(account: "herdr") == "k") }
    #expect(fake.calls("add") == ["herdr"] && fake.calls("read").count == 2 && fake.legacyWrites.isEmpty)
}

// MARK: Rule 4: one resolution per account per launch; set/re-enter updates cache + v2

@Test func eachAccountResolvesOncePerLaunch() {
    let fake = FakeKeychain(legacy: ["herdr": "k1"]); let keys = vault(fake)
    for _ in 0..<50 { #expect(keys.get(account: "herdr") == "k1") }
    #expect(fake.calls("read").count == 2)
}

@Test func setUpdatesCacheAndV2Only() {
    let fake = FakeKeychain(legacy: ["herdr": "k1"]); let defaults = isolatedDefaults(); let keys = vault(fake, defaults: defaults)
    _ = keys.get(account: "herdr")
    keys.set("k2", account: "herdr")
    #expect(keys.get(account: "herdr") == "k2" && fake.stored(v2, "herdr") == "k2" && fake.stored(legacy, "herdr") == "k1")
    #expect(fake.calls("read").count == 2 && fake.legacyWrites.isEmpty)
    let before = fake.calls.count
    keys.set("k2", account: "herdr")
    #expect(fake.calls.count == before)
}

@Test func clearingAKeyIsRememberedAcrossLaunchesWithoutDeletingLegacy() {
    let fake = FakeKeychain(legacy: ["herdr": "k1"]); let defaults = isolatedDefaults()
    vault(fake, defaults: defaults).set("", account: "herdr")
    let relaunched = vault(fake, defaults: defaults)
    #expect(relaunched.get(account: "herdr") == "" && !relaunched.exists(account: "herdr") && relaunched.accounts(prefix: "herdr").isEmpty)
    #expect(fake.calls("read", legacy).isEmpty && fake.stored(legacy, "herdr") == "k1" && fake.legacyWrites.isEmpty)
    relaunched.set("k3", account: "herdr")
    #expect(vault(fake, defaults: defaults).get(account: "herdr") == "k3")
}

@Test func reenteringALockedKeyClearsReentryWithoutReadingAgain() {
    let fake = FakeKeychain(legacy: ["herdr.grok-dmt": "old"]); fake.answer(legacy, "herdr.grok-dmt", with: errSecInteractionNotAllowed)
    let keys = vault(fake)
    _ = keys.get(account: "herdr.grok-dmt")
    keys.set("fresh", account: "herdr.grok-dmt")
    #expect(!keys.needsReentry(account: "herdr.grok-dmt") && keys.get(account: "herdr.grok-dmt") == "fresh")
    #expect(fake.stored(v2, "herdr.grok-dmt") == "fresh" && fake.calls("read", legacy).count == 1 && fake.legacyWrites.isEmpty)
}

@Test func concurrentReadsNeverOverlapAndResolveOnce() async {
    let fake = FakeKeychain(v2: ["herdr": "k", "herdr.cfo": "c", "herdr.ops": "o"]); fake.readDelay = 0.02
    let keys = vault(fake)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<30 { group.addTask { _ = keys.get(account: ["herdr", "herdr.cfo", "herdr.ops"][index % 3]) } }
    }
    #expect(fake.maxParallelReads == 1 && fake.calls("read").count == 3)
}

@Test func existsAndAccountsNeverReadData() {
    let fake = FakeKeychain(legacy: ["herdr": "k", "herdr.cfo": "c", "other": "o"], v2: ["herdr.ops": "o"]); let keys = vault(fake)
    #expect(keys.exists(account: "herdr.cfo") && keys.exists(account: "herdr.ops") && !keys.exists(account: "herdr.none"))
    #expect(keys.accounts(prefix: "herdr") == ["herdr", "herdr.cfo", "herdr.ops"])
    #expect(fake.calls("read").isEmpty)
}

@Test func recoveryIsClaimedOncePerAccountPerLaunch() {
    let keys = vault(FakeKeychain())
    #expect(keys.claimRecovery(account: "herdr.a") && !keys.claimRecovery(account: "herdr.a") && keys.claimRecovery(account: "herdr.b"))
}

/// The shared vault is the test-mode one: nothing is stored, and every call is reported (P28, `TestRunGuardTests`).
@Test func testRunsNeverReachTheRealKeychain() {
    #expect(KeyVault.isTestRun)
    withKnownIssue { KeychainStore.set("synthetic", account: "agentapp-tests.\(UUID().uuidString)") }
    withKnownIssue { #expect(!KeychainStore.exists(account: "herdr") && KeychainStore.accounts(prefix: "").isEmpty) }
}

// MARK: Rule 2 (derived keys) and rule 5: no dialog, no retry loop

private let jarvisKey = "jarvis-manager-key-0123456789abcdef"

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

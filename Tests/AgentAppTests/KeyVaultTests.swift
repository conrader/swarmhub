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
    let fake = FakeKeychain(legacy: ["hermes.grok-dmt": "old"], v2: ["hermes.grok-dmt": "new"])
    #expect(vault(fake).get(account: "hermes.grok-dmt") == "new")
    #expect(fake.calls("read") == ["hermes.grok-dmt"] && fake.calls("read", legacy).isEmpty)
}

@Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecIO])
func legacyItemThatNeedsADialogOrFailsLeavesTheKeyNeedingReentry(status: OSStatus) {
    let fake = FakeKeychain(legacy: ["hermes.grok-dmt": "old"]); fake.answer(legacy, "hermes.grok-dmt", with: status)
    let keys = vault(fake)
    for _ in 0..<10 { #expect(keys.get(account: "hermes.grok-dmt") == "") }
    #expect(keys.needsReentry(account: "hermes.grok-dmt") && keys.exists(account: "hermes.grok-dmt"))
    #expect(fake.calls("read", legacy).count == 1 && fake.calls("read", v2).count == 1)
    #expect(fake.calls("add").isEmpty && fake.legacyWrites.isEmpty && fake.stored(legacy, "hermes.grok-dmt") == "old")
}

@Test func missingKeyIsNotReentry() {
    let fake = FakeKeychain(); let keys = vault(fake)
    #expect(keys.get(account: "hermes.none") == "" && !keys.needsReentry(account: "hermes.none") && !keys.exists(account: "hermes.none"))
}

@Test func unreadableV2WithNoLegacyNeedsReentry() {
    let fake = FakeKeychain(v2: ["hermes.x": "v"]); fake.answer(v2, "hermes.x", with: errSecInteractionNotAllowed)
    let keys = vault(fake)
    #expect(keys.get(account: "hermes.x") == "" && keys.needsReentry(account: "hermes.x"))
}

// MARK: Rule 3: a legacy item that reads fine is copied to v2; legacy items are never deleted

@Test func readableLegacyKeyIsCopiedToV2AndLegacyIsKept() {
    let fake = FakeKeychain(legacy: ["hermes.grok-jarvis": "jk"]); let defaults = isolatedDefaults()
    #expect(vault(fake, defaults: defaults).get(account: "hermes.grok-jarvis") == "jk")
    #expect(fake.stored(v2, "hermes.grok-jarvis") == "jk" && fake.stored(legacy, "hermes.grok-jarvis") == "jk" && fake.legacyWrites.isEmpty)
    // Next launch reads v2 only.
    #expect(vault(fake, defaults: defaults).get(account: "hermes.grok-jarvis") == "jk")
    #expect(fake.calls("read", legacy).count == 1 && fake.calls("read", v2).count == 2 && fake.calls("add").count == 1)
}

@Test func onlyCopyingVaultsWriteV2OnRead() {
    let fake = FakeKeychain(legacy: ["hermes": "k"])
    #expect(KeyVault(backend: fake, defaults: isolatedDefaults(), copiesLegacy: false).get(account: "hermes") == "k")
    #expect(fake.calls("add").isEmpty && fake.calls("delete").isEmpty)
}

@Test func failedV2CopyStillServesTheKeyWithoutRetry() {
    let fake = FakeKeychain(legacy: ["hermes": "k"]); fake.addStatus = errSecIO; let keys = vault(fake)
    for _ in 0..<5 { #expect(keys.get(account: "hermes") == "k") }
    #expect(fake.calls("add") == ["hermes"] && fake.calls("read").count == 2 && fake.legacyWrites.isEmpty)
}

// MARK: Rule 4: one resolution per account per launch; set/re-enter updates cache + v2

@Test func eachAccountResolvesOncePerLaunch() {
    let fake = FakeKeychain(legacy: ["hermes": "k1"]); let keys = vault(fake)
    for _ in 0..<50 { #expect(keys.get(account: "hermes") == "k1") }
    #expect(fake.calls("read").count == 2)
}

@Test func setUpdatesCacheAndV2Only() {
    let fake = FakeKeychain(legacy: ["hermes": "k1"]); let defaults = isolatedDefaults(); let keys = vault(fake, defaults: defaults)
    _ = keys.get(account: "hermes")
    keys.set("k2", account: "hermes")
    #expect(keys.get(account: "hermes") == "k2" && fake.stored(v2, "hermes") == "k2" && fake.stored(legacy, "hermes") == "k1")
    #expect(fake.calls("read").count == 2 && fake.legacyWrites.isEmpty)
    let before = fake.calls.count
    keys.set("k2", account: "hermes")
    #expect(fake.calls.count == before)
}

@Test func clearingAKeyIsRememberedAcrossLaunchesWithoutDeletingLegacy() {
    let fake = FakeKeychain(legacy: ["hermes": "k1"]); let defaults = isolatedDefaults()
    vault(fake, defaults: defaults).set("", account: "hermes")
    let relaunched = vault(fake, defaults: defaults)
    #expect(relaunched.get(account: "hermes") == "" && !relaunched.exists(account: "hermes") && relaunched.accounts(prefix: "hermes").isEmpty)
    #expect(fake.calls("read", legacy).isEmpty && fake.stored(legacy, "hermes") == "k1" && fake.legacyWrites.isEmpty)
    relaunched.set("k3", account: "hermes")
    #expect(vault(fake, defaults: defaults).get(account: "hermes") == "k3")
}

@Test func reenteringALockedKeyClearsReentryWithoutReadingAgain() {
    let fake = FakeKeychain(legacy: ["hermes.grok-dmt": "old"]); fake.answer(legacy, "hermes.grok-dmt", with: errSecInteractionNotAllowed)
    let keys = vault(fake)
    _ = keys.get(account: "hermes.grok-dmt")
    keys.set("fresh", account: "hermes.grok-dmt")
    #expect(!keys.needsReentry(account: "hermes.grok-dmt") && keys.get(account: "hermes.grok-dmt") == "fresh")
    #expect(fake.stored(v2, "hermes.grok-dmt") == "fresh" && fake.calls("read", legacy).count == 1 && fake.legacyWrites.isEmpty)
}

@Test func concurrentReadsNeverOverlapAndResolveOnce() async {
    let fake = FakeKeychain(v2: ["hermes": "k", "hermes.cfo": "c", "hermes.ops": "o"]); fake.readDelay = 0.02
    let keys = vault(fake)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<30 { group.addTask { _ = keys.get(account: ["hermes", "hermes.cfo", "hermes.ops"][index % 3]) } }
    }
    #expect(fake.maxParallelReads == 1 && fake.calls("read").count == 3)
}

@Test func existsAndAccountsNeverReadData() {
    let fake = FakeKeychain(legacy: ["hermes": "k", "hermes.cfo": "c", "other": "o"], v2: ["hermes.ops": "o"]); let keys = vault(fake)
    #expect(keys.exists(account: "hermes.cfo") && keys.exists(account: "hermes.ops") && !keys.exists(account: "hermes.none"))
    #expect(keys.accounts(prefix: "hermes") == ["hermes", "hermes.cfo", "hermes.ops"])
    #expect(fake.calls("read").isEmpty)
}

@Test func recoveryIsClaimedOncePerAccountPerLaunch() {
    let keys = vault(FakeKeychain())
    #expect(keys.claimRecovery(account: "hermes.a") && !keys.claimRecovery(account: "hermes.a") && keys.claimRecovery(account: "hermes.b"))
}

@Test func testRunsNeverReachTheRealKeychain() {
    #expect(KeyVault.isTestRun)
    KeychainStore.set("synthetic", account: "agentapp-tests.\(UUID().uuidString)")
    #expect(!KeychainStore.exists(account: "hermes") && KeychainStore.accounts(prefix: "").isEmpty)
}

// MARK: Rule 2 (derived keys) and rule 5: no dialog, no retry loop

private let jarvisKey = "jarvis-manager-key-0123456789abcdef"

/// A store on a synthetic Hermes whose `/p/<profile>/v1/models` answers 200 only for the P22 derived key of `served`
/// profiles, with a fake Keychain where `grok-jarvis` (the manager) reads fine and the `locked` profiles need a dialog.
@MainActor private func recoveryStore(locked: [String], served: Set<String>, manager: Bool = true)
    -> (AppStore, FakeKeychain, String, [String: Bot]) {
    let probe = MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "p", parts[2...] == ["v1", "models"], served.contains(parts[1]) else { return (404, ["error": "no route"]) }
        let expected = "Bearer " + BotManagerText.derivedKey(managerKey: jarvisKey, botName: parts[1])
        return request.value(forHTTPHeaderField: "Authorization") == expected ? (200, ["data": [["id": parts[1]]]]) : (401, ["error": "bad key"])
    }
    var legacyItems = ["hermes.grok-jarvis": jarvisKey]
    for profile in locked { legacyItems["hermes.\(profile)"] = "old-\(profile)" }
    let fake = FakeKeychain(legacy: legacyItems)
    for profile in locked { fake.answer(legacy, "hermes.\(profile)", with: errSecInteractionNotAllowed) }
    let defaults = isolatedDefaults(); defaults.set("https://\(probe.host)", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: KeychainHermesKeyStore(vault: vault(fake)), defaults: defaults, hermesSession: probe.session)
    let jarvis = Bot(name: "Jarvis", persona: "", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = manager
    var bots = ["grok-jarvis": jarvis]
    for profile in locked { bots[profile] = Bot(name: profile, persona: "", backend: .hermes, hermesProfile: profile) }
    store.bots = [jarvis] + locked.compactMap { bots[$0] }
    return (store, fake, probe.host, bots)
}

@MainActor @Test func lockedKeyIsDerivedFromTheManagerProbedAndSavedToV2() async throws {
    let (store, fake, host, bots) = recoveryStore(locked: ["grok-dmt", "grok-vised"], served: ["grok-dmt", "grok-vised"])
    await store.recoverLockedKeys()
    for profile in ["grok-dmt", "grok-vised"] {
        let derived = BotManagerText.derivedKey(managerKey: jarvisKey, botName: profile)
        #expect(fake.stored(v2, "hermes.\(profile)") == derived && fake.stored(legacy, "hermes.\(profile)") == "old-\(profile)")
        #expect(!store.keyNeedsReentry(bots[profile]!) && !store.needsKey(bots[profile]!))
        #expect((try store.backend(for: bots[profile]!) as? HermesBackend)?.apiKey == derived)
    }
    #expect(MockHermesProtocol.recorded(host).map(\.url!.path).sorted() == ["/p/grok-dmt/v1/models", "/p/grok-vised/v1/models"])
    #expect(fake.calls("read", legacy).sorted() == ["hermes.grok-dmt", "hermes.grok-jarvis", "hermes.grok-vised"] && fake.legacyWrites.isEmpty)
    // The next launch reads the derived key from v2: no legacy read, no probe.
    let relaunched = KeyVault(backend: fake, defaults: isolatedDefaults())
    #expect(relaunched.get(account: "hermes.grok-dmt") == BotManagerText.derivedKey(managerKey: jarvisKey, botName: "grok-dmt"))
    #expect(fake.calls("read", legacy).count == 3)
}

@MainActor @Test func rejectedDerivedKeyLeavesReenterAndIsNotRetried() async throws {
    let (store, fake, host, bots) = recoveryStore(locked: ["grok-doc"], served: [])
    await store.recoverLockedKeys(); await store.recoverLockedKeys()
    let bot = bots["grok-doc"]!
    #expect(store.keyNeedsReentry(bot) && store.needsKey(bot) && fake.stored(v2, "hermes.grok-doc") == nil)
    #expect(MockHermesProtocol.recorded(host).count == 1 && fake.calls("read", legacy).filter { $0 == "hermes.grok-doc" }.count == 1)
    for _ in 0..<5 {
        do { _ = try store.backend(for: bot); Issue.record("expected re-entry") } catch { #expect(error.localizedDescription == KeychainStore.reenterMessage) }
    }
    let check = await HeadlessCommands.checkBot(bot, store: store)
    #expect(check.key == .locked && check.problem == KeychainStore.reenterMessage)
    #expect(fake.calls("read", legacy).filter { $0 == "hermes.grok-doc" }.count == 1 && MockHermesProtocol.recorded(host).count == 1)
    store.saveKey("pasted", for: bot)
    #expect(!store.keyNeedsReentry(bot) && fake.stored(v2, "hermes.grok-doc") == "pasted")
    #expect((try store.backend(for: bot) as? HermesBackend)?.apiKey == "pasted")
}

@MainActor @Test func lockedKeyWithoutAManagerOnItsConnectionIsNotDerived() async {
    let (store, fake, host, bots) = recoveryStore(locked: ["grok-rapper"], served: ["grok-rapper"], manager: false)
    await store.recoverLockedKeys()
    #expect(store.keyNeedsReentry(bots["grok-rapper"]!) && MockHermesProtocol.recorded(host).isEmpty && fake.stored(v2, "hermes.grok-rapper") == nil)
}

@MainActor @Test func lockedKeyWithAnUnreadableManagerKeyIsNotDerived() async {
    let (store, fake, host, bots) = recoveryStore(locked: ["grok-infra"], served: ["grok-infra"])
    fake.answer(legacy, "hermes.grok-jarvis", with: errSecInteractionNotAllowed)
    await store.recoverLockedKeys()
    #expect(store.keyNeedsReentry(bots["grok-infra"]!) && MockHermesProtocol.recorded(host).isEmpty)
}

@MainActor @Test func botOnAnotherConnectionIsNotDerivedFromThisManager() async {
    let (store, _, host, bots) = recoveryStore(locked: ["grok-saldora"], served: ["grok-saldora"])
    bots["grok-saldora"]!.hermesBaseURL = "https://other-\(UUID().uuidString.lowercased()).test"
    await store.recoverLockedKeys()
    #expect(store.keyNeedsReentry(bots["grok-saldora"]!) && MockHermesProtocol.recorded(host).isEmpty)
}

@MainActor @Test func storeKeyPathsResolveEachAccountOnce() throws {
    let fake = FakeKeychain(legacy: ["hermes": "k", "hermes.cfo": "c"])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: KeychainHermesKeyStore(vault: vault(fake)), defaults: isolatedDefaults())
    let bot = Bot(name: "CFO", persona: "", backend: .hermes, hermesProfile: "cfo")
    for _ in 0..<20 {
        #expect(!store.needsKey(bot) && store.hermesConfigured)
        #expect((try store.backend(for: bot) as? HermesBackend)?.apiKey == "c")
    }
    #expect(fake.calls("read", legacy).sorted() == ["hermes", "hermes.cfo"])
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

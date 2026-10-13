import Foundation
import Testing
@testable import AgentApp

private let jarvisID = "00000000-0000-4000-8000-000000000001"
private let plainID = "00000000-0000-4000-8000-000000000003"
private let server = "https://box.test/v1"

private func native() throws -> [GrokBotBundle] {
    GrokBundleBuilder.build(try GrokCacheReader(folder: grokCacheFixture).read()).bundles.map(GrokBotBundle.init)
}

@MainActor private func policyStore(server: String? = nil, keys: [String: String] = [:], url: URL = temporaryStore()) -> AppStore {
    let defaults = isolatedDefaults()
    if let server { defaults.set(server, forKey: "hermesBaseURL") }
    return AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: defaults)
}

/// The synchronous overload (an async context would pick the async one).
@MainActor private func importOnMainActor(_ store: AppStore, _ bundles: [GrokBotBundle], policy: GrokImportPolicy) throws {
    try store.importGrokBundles(bundles, policy: policy)
}

private func inApp(_ server: String? = nil, refresh: Bool = false) -> GrokImportPolicy {
    .inApp(serverURL: server, refreshIdentity: refresh)
}

@MainActor @Test func inAppNewBotsTakeTheSettingsServerNeverTheConstant() async throws {
    let store = policyStore(server: server)
    let rows = try await store.importGrokBundles(try native(), policy: inApp(server))
    #expect(rows.count == 4 && rows.allSatisfy(\.created))
    let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
    #expect(jarvis.hermesBaseURL == server && jarvis.hermesProfile == "grok-jarvis" && jarvis.backend == .hermes)
    #expect(!store.bots.contains { $0.hermesBaseURL == AppStore.grokHermesBaseURL })
    #expect(jarvis.grokHistoryCount == 9 && store.groups.first?.grokHistoryCount == 3)
}

@MainActor @Test func inAppBindingPrefersAKeyedCandidateThenAFreeOneThenNone() async throws {
    // A key for the third candidate (`<slug>`) wins over the free first one.
    let keyed = policyStore(server: server, keys: ["hermes.jarvis": "synthetic-key"])
    try await keyed.importGrokBundles(try native(), policy: inApp(server))
    #expect(keyed.bots.first { $0.grokSourceID == jarvisID }?.hermesProfile == "jarvis")
    #expect(keyed.bots.first { $0.grokSourceID == plainID }?.hermesProfile == "grok-plain-bot")
    // A key but no server: the keyed candidate only; the rest are history-only.
    let noServer = policyStore(keys: ["hermes.grok-jarvis": "synthetic-key"])
    try await noServer.importGrokBundles(try native(), policy: inApp())
    let jarvis = try #require(noServer.bots.first { $0.grokSourceID == jarvisID })
    let plain = try #require(noServer.bots.first { $0.grokSourceID == plainID })
    #expect(jarvis.hermesProfile == "grok-jarvis" && jarvis.hermesBaseURL == nil && !jarvis.isGrokHistoryOnly)
    #expect(plain.hermesProfile == nil && plain.isGrokHistoryOnly && plain.hermesBaseURL == nil)
}

@MainActor @Test func historyOnlyBotsNeverChatOrFallThroughToTheDefaultServer() async throws {
    let store = policyStore()
    try await store.importGrokBundles(try native(), policy: inApp())
    let plain = try #require(store.bots.first { $0.grokSourceID == plainID })
    #expect(plain.isGrokHistoryOnly && !store.needsKey(plain))
    store.selectedBot = plain
    #expect(store.send(text: "hi") == false && plain.messages.isEmpty && store.errorMessage == nil)
    #expect(throws: BackendError.self) { _ = try store.backend(for: plain) }
    #expect(store.grokHistory.messages(for: plain.id).isEmpty && store.bindUnboundGrokBots().isEmpty)
    // Keys added later: "Check again" binds fill-only and never replaces an existing profile.
    let keys = InMemoryKeyStore(["hermes.grok-plain-bot": "synthetic-key"])
    let rebound = AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: keys, defaults: isolatedDefaults())
    let bound = rebound.bindUnboundGrokBots()
    #expect(bound.map(\.grokSourceID) == [plainID] && bound.first?.hermesProfile == "grok-plain-bot")
    #expect(rebound.bots.filter(\.isGrokHistoryOnly).count == 2)
    #expect(AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: keys, defaults: isolatedDefaults())
        .bots.first { $0.grokSourceID == plainID }?.hermesProfile == "grok-plain-bot")
}

@MainActor @Test func linkedBotsGetHistoryOnlyUnlessRefreshIdentity() async throws {
    let store = policyStore(server: server)
    try await store.importGrokBundles(try native(), policy: inApp(server))
    let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
    jarvis.name = "My Jarvis"; jarvis.persona = "local persona"
    jarvis.hermesProfile = "custom"; jarvis.hermesBaseURL = "https://other.test/v1"
    jarvis.avatarName = .fox
    var bundles = try native()
    bundles[0].messages.append(.init(id: "j99", seq: 99, role: "user", author: nil, text: "new synthetic line",
                                     timestamp: nil, hidden: false, channel: "chat", to: nil))
    let rows = try await store.importGrokBundles(bundles, policy: inApp(server))
    #expect(rows.allSatisfy { !$0.created } && store.bots.filter { $0.grokSourceID != nil }.count == 3)
    #expect(jarvis.name == "My Jarvis" && jarvis.persona == "local persona" && jarvis.avatarName == .fox)
    #expect(jarvis.hermesProfile == "custom" && jarvis.hermesBaseURL == "https://other.test/v1" && jarvis.grokHistoryCount == 10)
    store.groups[0].name = "Renamed group"
    try await store.importGrokBundles(bundles, policy: inApp(server))
    #expect(store.groups[0].name == "Renamed group")
    try await store.importGrokBundles(bundles, policy: inApp(server, refresh: true))
    #expect(jarvis.name == "Jarvis" && jarvis.persona.contains("[REDACTED]") && jarvis.avatarName == .blob)
    #expect(jarvis.hermesProfile == "custom" && jarvis.hermesBaseURL == "https://other.test/v1" && jarvis.grokHistoryCount == 10)
    #expect(store.groups[0].name == "Konrad, Jarvis, Plain Bot")
}

@MainActor @Test func inAppAdoptsAnUnclaimedHermesBotOnAnyCandidate() async throws {
    let store = policyStore(server: server)
    let existing = Bot(name: "jarvis", backend: .hermes, hermesProfile: "jarvis")
    existing.hermesBaseURL = "https://own.test/v1"
    store.bots.append(existing)
    let rows = try await store.importGrokBundles(try native(), policy: inApp(server))
    #expect(rows.first { $0.name == "Jarvis" }?.created == false)
    #expect(existing.grokSourceID == jarvisID && existing.name == "Jarvis" && existing.avatarName == .blob)
    #expect(existing.hermesProfile == "jarvis" && existing.hermesBaseURL == "https://own.test/v1")
    #expect(store.bots.filter { $0.name == "Jarvis" }.count == 1)
}

@MainActor @Test func hiddenFromSidebarAppliesOnCreationOnly() async throws {
    var bundles = try native()
    let plainIndex = try #require(bundles.firstIndex { $0.sourceId == plainID })
    bundles[plainIndex].source?.hiddenFromSidebar = true
    let store = policyStore(server: server)
    try await store.importGrokBundles(bundles, policy: inApp(server))
    let plain = try #require(store.bots.first { $0.grokSourceID == plainID })
    #expect(plain.isHidden && store.bots.first { $0.grokSourceID == jarvisID }?.isHidden == false)
    plain.isHidden = false
    try await store.importGrokBundles(bundles, policy: inApp(server, refresh: true))
    #expect(!plain.isHidden)
    // The legacy path keeps today's behaviour.
    let legacy = policyStore()
    try legacy.importGrokBundles(bundles)
    #expect(legacy.bots.first { $0.grokSourceID == plainID }?.isHidden == false)
}

@MainActor @Test func bothPoliciesRefuseAStoreThatCannotSave() async throws {
    let demo = AppStore(demoMode: true, storeURL: temporaryStore(), autoConfigureHermes: false,
                        keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let botCount = demo.bots.count
    #expect(throws: GrokImportError.persistenceDisabled) { try demo.importGrokBundles(try native()) }
    await #expect(throws: GrokImportError.persistenceDisabled) { try await demo.importGrokBundles(try native(), policy: inApp()) }
    #expect(demo.bots.count == botCount)
    // A failed write of store.json is an error, not a green run.
    let store = policyStore()
    try FileManager.default.removeItem(at: store.fileURL)
    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
    #expect(throws: GrokImportError.saveFailed) { try store.importGrokExport(at: grokGoldenExport) }
    await #expect(throws: GrokImportError.saveFailed) { try await store.importGrokBundles(try native(), policy: inApp()) }
}

@MainActor @Test func anUnreadableArchiveIsSetAsideNeverOverwritten() async throws {
    for useLegacy in [true, false] {
        let store = policyStore()
        try store.importGrokExport(at: grokGoldenExport)
        let jarvis = try #require(store.bots.first { $0.grokSourceID == jarvisID })
        let file = store.grokHistory.fileURL(for: jarvis.id)
        #expect(store.grokHistory.lastModified(for: jarvis.id) != nil)
        try Data("not json".utf8).write(to: file)
        var kept: String?
        do {
            if useLegacy { try store.importGrokExport(at: grokGoldenExport) }
            else { try await store.importGrokBundles(try native(), policy: inApp()) }
        } catch GrokHistoryError.archiveUnreadable(let name) { kept = name }
        let name = try #require(kept)
        #expect(name.hasPrefix("\(file.lastPathComponent).corrupt-") && !name.contains(":"))
        let backup = file.deletingLastPathComponent().appending(path: name)
        #expect(try Data(contentsOf: backup) == Data("not json".utf8))
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: file.path) && store.grokHistory.lastModified(for: jarvis.id) == nil)
        #expect(GrokHistoryError.archiveUnreadable(keptAs: name).localizedDescription.contains("nothing deleted"))
    }
}

@MainActor @Test func crossPathImportIsIdempotent() async throws {
    let store = policyStore(server: server)
    try store.importGrokExport(at: grokGoldenExport)
    let before = store.bots.filter { $0.grokSourceID != nil }
        .map { ($0.id, $0.grokHistoryCount, store.grokHistory.messages(for: $0.id).map(\.id)) }
    let groupsBefore = store.groups.map { ($0.id, $0.grokHistoryCount) }
    let botCount = store.bots.count
    let rows = try await store.importGrokBundles(try native(), policy: inApp(server))
    #expect(rows.allSatisfy { !$0.created } && store.bots.count == botCount && store.groups.count == groupsBefore.count)
    for (id, count, ids) in before {
        #expect(store.bots.first { $0.id == id }?.grokHistoryCount == count)
        #expect(store.grokHistory.messages(for: id).map(\.id) == ids)
    }
    #expect(store.groups.map { ($0.id, $0.grokHistoryCount) }.elementsEqual(groupsBefore) { $0 == $1 })
}

@MainActor @Test func inAppCommitOfALargeBundleKeepsTheMainActorResponsive() async throws {
    var big = try #require(try native().first { $0.sourceId == jarvisID })
    big.messages = (1...3000).map {
        .init(id: "m\($0)", seq: Int64($0), role: $0 % 2 == 0 ? "assistant" : "user", author: nil,
              text: "synthetic line \($0) with token=FAKE\($0) and some more words to redact", timestamp: "2025-10-09T08:53:22.000Z",
              hidden: false, channel: "chat", to: nil)
    }
    let store = policyStore(server: server), timing = GrokImportTiming(), clock = ContinuousClock()
    let start = clock.now
    try await store.importGrokBundles([big], policy: inApp(server), timing: timing)
    let wall = clock.now - start
    let syncStore = policyStore(server: server), syncStart = clock.now
    try importOnMainActor(syncStore, [big], policy: inApp(server))
    print("P10a main-actor: 3,000-message bundle, longest stretch \(timing.longest), main-actor total \(timing.total),"
          + " wall \(wall); sync path \(clock.now - syncStart)")
    #expect(store.bots.first { $0.grokSourceID == jarvisID }?.grokHistoryCount == 3001)   // + the rename line
    #expect(timing.stretches.count >= 4 && timing.longest < .milliseconds(100))
    let archive = store.grokHistory.fileURL(for: try #require(store.bots.first { $0.grokSourceID == jarvisID }).id)
    #expect(!String(decoding: try Data(contentsOf: archive), as: UTF8.self).contains("FAKE1"))
}

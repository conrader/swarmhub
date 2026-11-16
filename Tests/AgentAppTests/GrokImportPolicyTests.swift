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
    if server != nil { defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey) }
    return AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(keys), defaults: defaults)
}

/// The synchronous overload (an async context would pick the async one).
@MainActor private func importOnMainActor(_ store: AppStore, _ bundles: [GrokBotBundle], policy: GrokImportPolicy) throws {
    try store.importGrokBundles(bundles, policy: policy)
}

private func inApp(_ server: String? = nil, refresh: Bool = false) -> GrokImportPolicy {
    .inApp(refreshIdentity: refresh)
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
    let demo = AppStore(demoMode: true, storeURL: temporaryStore(), autoStart: false,
                        keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let botCount = demo.bots.count
    #expect(throws: GrokImportError.persistenceDisabled) { try demo.importGrokBundles(try native()) }
    await #expect(throws: GrokImportError.persistenceDisabled) { try await demo.importGrokBundles(try native(), policy: inApp()) }
    #expect(demo.bots.count == botCount)
    // A failed write of store.json is an error, not a green run.
    let store = policyStore()
    // P21 D3: a fresh store no longer writes sample bots, so store.json may not exist yet.
    try? FileManager.default.removeItem(at: store.fileURL)
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

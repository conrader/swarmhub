import Foundation
import Testing
@testable import AgentApp

// P49: a new bot orients itself once: only the manager's `bot_created` and a Grok import that makes a new bot queue it;
// it is sent when the bot answers, waits while it does not, and is given up after 24 h. Fakes only: an in-memory
// backend and an in-process models probe; no network, Keychain, browser or microphone.

private let managerKey = "0123456789abcdef0123456789abcdef"

/// Answers every turn with "ok" and records what was sent; `testConnection` fails while `reachable` is false.
actor OrientationFakeBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    nonisolated let sent = AwaitableLog<String>()
    private var reachable: Bool
    init(reachable: Bool = true) { self.reachable = reachable }
    func setReachable(_ value: Bool) { reachable = value }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sent.append(request.messages.last?.content ?? "")
        return AsyncThrowingStream { $0.yield(.token("Hi Konrad, here.")); $0.yield(.completed); $0.finish() }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String {
        guard reachable else { throw BackendError.unavailable("box unreachable") }
        return "ok"
    }
}

/// A store with Jarvis managing the box; `/p/<name>/v1/models` answers for `served` with the derived key.
@MainActor func orientationStore(_ fake: OrientationFakeBackend = OrientationFakeBackend(), served: Set<String> = ["scout"],
                                 defaults: UserDefaults = namedDefaults(), url: URL = temporaryStore()) -> (AppStore, Bot) {
    let probe = MockHermesProtocol.serve { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "p", served.contains(parts[1]) else { return (404, ["error": "no route"]) }
        return (200, ["data": [["id": parts[1]]]])
    }
    defaults.set("https://\(probe.host)", forKey: "hermesBaseURL")
    let keys = InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": managerKey])
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in fake }, keyStore: keys, defaults: defaults, hermesSession: probe.session)
    store.botProbeAttempts = 1
    let jarvis = Bot(name: "Jarvis", description: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis)
}

@MainActor private func created(_ store: AppStore, _ manager: Bot, name: String = "scout") async throws -> Bot {
    await store.apply(.botCreated(name: name, description: "Finds things", avatar: nil), manager: manager)
    return try #require(store.bots.first { $0.hermesProfile == name })
}

@MainActor private func orientationRows(_ bot: Bot) -> [ChatMessage] { bot.messages.filter { $0.metadata[AutomationKey.orientation] == "1" } }

@MainActor @Test func managerCreateQueuesOneOrientationThatIsSentWhenTheBotAnswers() async throws {
    let fake = OrientationFakeBackend()
    let (store, jarvis) = orientationStore(fake)
    let scout = try await created(store, jarvis)
    #expect(store.orientationPending(scout) && scout.orientedAt == nil)
    await store.orientationPass()
    try await waitUntil { !store.anyTurnRunning }
    let rows = orientationRows(scout)
    #expect(rows.count == 1 && rows[0].role == .user && rows[0].metadata[AutomationKey.display] == "Orientation")
    #expect(scout.messages.last?.role == .assistant && scout.messages.last?.content == "Hi Konrad, here.", "the reply shows normally")
    #expect(scout.orientedAt != nil && !store.orientationPending(scout))
    #expect(jarvis.messages.allSatisfy { $0.metadata[AutomationKey.orientation] == nil }, "the manager gets no orientation")
    // Once per bot: more passes, a reconnect or a key change send nothing more.
    await store.orientationPass(); await store.handle(.pathUp)
    store.saveKey("changed", for: scout); await store.orientationPass()
    try await waitUntil { !store.anyTurnRunning }
    #expect(orientationRows(scout).count == 1 && fake.sent.all.count == 1)
}

@MainActor @Test func addingAProfileThatAlreadyExistedNeverOrients() async throws {
    let (store, jarvis) = orientationStore(served: ["scout"])
    store.botOffers[jarvis.id] = [BotOffer(name: "scout", description: "")]
    await store.addOffered(try #require(store.botOffers[jarvis.id]?.first), manager: jarvis)
    let scout = try #require(store.bots.first { $0.hermesProfile == "scout" })
    #expect(!store.orientationPending(scout) && scout.orientedAt != nil)
}

@MainActor @Test func grokImportOrientsNewBotsWithAProfileOnly() async throws {
    let fake = OrientationFakeBackend()
    let (store, jarvis) = orientationStore(fake)
    let bundles = GrokBundleBuilder.build(try GrokCacheReader(folder: grokCacheFixture).read()).bundles.map(GrokBotBundle.init)
    try await store.importGrokBundles(bundles, policy: .inApp(serverURL: "https://box.test/v1", refreshIdentity: false))
    // Jarvis already existed on grok-jarvis: the import adopts it (no orientation); the others are new bots.
    #expect(jarvis.grokSourceID != nil && !store.orientationPending(jarvis))
    let imported = store.bots.filter { $0.grokSourceID != nil && !$0.isReadOnlyArchive && $0 !== jarvis }
    #expect(!imported.isEmpty && imported.contains { $0.hermesProfile != nil })
    #expect(imported.allSatisfy { store.orientationPending($0) == ($0.hermesProfile != nil) })
    // A second import links the same bots: nothing new is queued, and what was sent stays sent.
    imported.forEach { $0.orientedAt = .now; $0.orientationQueuedAt = nil }
    try await store.importGrokBundles(bundles, policy: .inApp(serverURL: "https://box.test/v1", refreshIdentity: true))
    #expect(store.bots.allSatisfy { !store.orientationPending($0) })
}

@MainActor @Test func plainBotsAndOldStoreEntriesCountAsOriented() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let old = Bot(name: "Old", backend: .hermes, hermesProfile: "old"), pending = Bot(name: "New", backend: .hermes, hermesProfile: "new")
    store.bots = [old, pending]; store.queueOrientation(pending)
    #expect(old.orientedAt != nil && !store.orientationPending(old))
    // A store.json written before P49 has neither key: the bot is oriented and stays so.
    var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var bots = try #require(json["bots"] as? [[String: Any]])
    bots[0].removeValue(forKey: "orientedAt"); bots[0].removeValue(forKey: "orientationQueuedAt"); json["bots"] = bots
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let reopenedOld = try #require(restored.bots.first { $0.name == "Old" }), reopenedNew = try #require(restored.bots.first { $0.name == "New" })
    #expect(reopenedOld.orientedAt == old.createdAt && !restored.orientationPending(reopenedOld))
    #expect(restored.orientationPending(reopenedNew), "a waiting orientation survives a restart")
}

@MainActor @Test func anUnreachableBotWaitsAndOrientsOnTheNextConnect() async throws {
    let fake = OrientationFakeBackend(reachable: false)
    let (store, jarvis) = orientationStore(fake)
    let scout = try await created(store, jarvis)
    await store.orientationPass()
    #expect(store.orientationPending(scout) && orientationRows(scout).isEmpty && fake.sent.all.isEmpty)
    // Offline: the pass does not even ask.
    await store.handle(.pathDown); await fake.setReachable(true); await store.orientationPass()
    #expect(store.orientationPending(scout))
    await store.handle(.pathUp)
    try await waitUntil { !store.anyTurnRunning && !orientationRows(scout).isEmpty }
    #expect(orientationRows(scout).count == 1 && !store.orientationPending(scout))
}

@MainActor @Test func anOrientationIsGivenUpAfter24HoursWithOneQuietLine() async throws {
    let (store, jarvis) = orientationStore(OrientationFakeBackend(reachable: false))
    var clock = Date(timeIntervalSince1970: 5_000_000); store.now = { clock }
    let scout = try await created(store, jarvis)
    clock += 23 * 3600; await store.orientationPass()
    #expect(store.orientationPending(scout) && scout.messages.isEmpty)
    clock += 3600; await store.orientationPass(); await store.orientationPass()
    #expect(!store.orientationPending(scout) && scout.orientedAt == clock)
    #expect(scout.messages.map(\.content) == [OrientationCopy.gaveUp("Scout")] && scout.messages[0].metadata[TurnKey.tone] == nil)
}

@MainActor @Test func switchedOffInSettingsNothingIsQueuedOrSent() async throws {
    let fake = OrientationFakeBackend(), defaults = namedDefaults()
    defaults.set(false, forKey: OrientationCopy.enabledKey)
    let (store, jarvis) = orientationStore(fake, defaults: defaults)
    let scout = try await created(store, jarvis)
    await store.orientationPass()
    #expect(!store.orientationPending(scout) && scout.messages.isEmpty && fake.sent.all.isEmpty)
}

@MainActor @Test func aRetryPassRunsAtMostOnceAMinute() async throws {
    let fake = OrientationFakeBackend(reachable: false)
    let (store, jarvis) = orientationStore(fake)
    var clock = Date(timeIntervalSince1970: 6_000_000); store.now = { clock }
    let scout = try await created(store, jarvis)
    await store.orientationPassIfDue(); await fake.setReachable(true)
    clock += 30; await store.orientationPassIfDue()
    #expect(store.orientationPending(scout))
    clock += 31; await store.orientationPassIfDue()
    try await waitUntil { !store.anyTurnRunning }
    #expect(!store.orientationPending(scout) && orientationRows(scout).count == 1)
}

import Foundation
import Testing
@testable import AgentApp

// P28 D6: `/v1/capabilities` with a key the box rejects. One request for concurrent callers, a backoff instead of a loop,
// the bot's key state shown (no dialog), and a different (re-entered) key read at once. Synthetic box only.

private func capabilityGets(_ state: E2EServer.State) -> Int {
    state.requests().filter { $0.method == "GET" && $0.path.hasSuffix("/v1/capabilities") }.count
}

@Test func aRejectedKeyIsAskedOnceThenBacksOff() async throws {
    let server = E2EServer.serve()
    server.state.with { $0.keys = ["grok-jarvis": "right-key"] }
    let base = URL(string: "https://\(server.host)/v1")!
    let wrong = HermesBackend(baseURL: base, apiKey: "wrong-key", profile: "grok-jarvis", session: server.session)
    // Concurrent readers (Overview capabilities, chat features, a reconcile's transport) share one request.
    async let a: Set<String>? = try? wrong.features()
    async let b: HermesCapabilities?? = try? wrong.capabilities()
    async let c: HermesTransport? = try? wrong.transport()
    _ = await (a, b, c)
    #expect(capabilityGets(server.state) == 1)
    // Later passes inside the backoff get the stored 401 without a request.
    for _ in 0..<5 {
        await #expect(throws: BackendError.self) { _ = try await wrong.features() }
        await #expect(throws: BackendError.self) { _ = try await wrong.capabilities() }
    }
    #expect(capabilityGets(server.state) == 1)
    let backoff = try #require(await HermesCapabilityRegistry.shared.backoff(for: wrong.capabilityScope))
    #expect(backoff > 0 && backoff <= HermesCapabilityRegistry.firstBackoff)
    do { _ = try await wrong.features(); Issue.record("no error") } catch {
        #expect(BotInfoCache.describe(error, key: wrong.apiKey) == "HTTP 401: the server rejected this bot's key.")
    }
    #expect(!wrong.capabilityScope.contains("wrong-key"), "the scope keeps a digest, never the key")

    // The right key (re-entered) is a different scope and is read at once.
    let right = HermesBackend(baseURL: base, apiKey: "right-key", profile: "grok-jarvis", session: server.session)
    #expect(try await right.features().contains("run_steer"))
    #expect(capabilityGets(server.state) == 2)
}

@Test func theBackoffDoublesAndEndsAtTenMinutes() async throws {
    let registry = HermesCapabilityRegistry()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let calls = LockedValue(0)
    let reject: @Sendable () async throws -> HermesCapabilityRegistry.Read = { _ = calls.swap(calls.current + 1); throw BackendError.http(401, "Invalid API key") }
    var now = start
    var waits: [TimeInterval] = []
    for _ in 0..<7 {
        _ = try? await registry.read("scope", now: now, fetch: reject)
        let wait = try #require(await registry.backoff(for: "scope", now: now))
        waits.append(wait.rounded()); now = now.addingTimeInterval(wait)
    }
    #expect(waits == [30, 60, 120, 240, 480, 600, 600])
    #expect(calls.current == 7)
    // A success clears it.
    _ = try await registry.read("scope", now: now) { .init(json: ["features": [:]]) }
    #expect(await registry.backoff(for: "scope", now: now) == nil)
}

@MainActor @Test func aStoreWithAWrongKeyDoesNotLoopOnCapabilities() async throws {
    let server = E2EServer.serve()
    server.state.with { $0.keys = ["grok-jarvis": "right-key"] }
    let defaults = isolatedDefaults(); defaults.set("https://\(server.host)", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "stale-key"]),
                         defaults: defaults, hermesSession: server.session)
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis", hermesSessionID: "s-jarvis")
    store.bots = [jarvis]
    // Opening the chat (features + reconcile), the Overview load, and several timed passes.
    store.open(jarvis)
    await store.loadServerInfo(for: jarvis)
    for _ in 0..<4 { await store.reconcile(jarvis, reason: .refresh); store.refreshFeatures(for: jarvis) }
    await store.loadServerInfo(for: jarvis)
    try await Task.sleep(for: .milliseconds(100))
    #expect(capabilityGets(server.state) == 1)
    #expect(server.state.requests().filter { !$0.path.hasSuffix("/health") }.allSatisfy { $0.path.hasSuffix("/v1/capabilities") }, "nothing else is tried with a rejected key")
    // The Overview shows the existing key state; no alert is raised.
    let info = try #require(store.botInfo.info(for: jarvis.id))
    #expect(info.lastLoadFailed && info.skills == .failed("HTTP 401: the server rejected this bot's key."))
    #expect(store.errorMessage == nil)
    // An automatic pass against a box that answered 401 is not "unreachable" (no quick retries).
    let report = await store.reconcile(jarvis, reason: .refresh)
    #expect(!report.unreachable && report.read == 0)
}

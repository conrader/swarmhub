import Foundation
import Testing
@testable import AgentApp

// P13 Part C: what ran. `runtime{}` from the session stream (memory only), the Overview's "Last turn ran on" and
// mismatch lines, "Use the box default instead", and `--e2e --roles` (step g) against the synthetic gateway.

private let alpha = ModelChoice(provider: "lab-one", model: "model-alpha")!
private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private func sessionOf(_ bot: Bot) -> String { "agentapp_\(bot.id.uuidString.lowercased())" }

// MARK: Parse

@Test func runtimeParsesBothShapesAndIgnoresEverythingElse() {
    let v0205: [String: Any] = ["provider": "lab-one", "model": "model-beta", "route_source": "session_lock", "requested": NSNull(), "model_lock": "accepted"]
    let v0217: [String: Any] = ["provider": "lab-one", "model": "model-beta", "route_source": "session_lock", "model_lock": "accepted",
                                "requested": ["provider": "lab-one", "model": "model-beta"]]
    #expect(HermesRuntime.parse(v0205) == HermesRuntime(model: "model-beta", provider: "lab-one"))
    #expect(HermesRuntime.parse(v0217) == HermesRuntime(model: "model-beta", provider: "lab-one"))
    #expect(HermesRuntime.parse([String: Any]()) == nil, "0.21.x replays carry {}")
    #expect(HermesRuntime.parse(["provider": "lab-one"]) == nil)
    #expect(HermesRuntime.parse(["model": ""]) == nil)
    #expect(HermesRuntime.parse(["model": 42, "provider": "lab-one"] as [String: Any]) == nil)
    #expect(HermesRuntime.parse(["model": "model-beta", "provider": 7] as [String: Any]) == HermesRuntime(model: "model-beta", provider: nil))
    #expect(HermesRuntime.parse("model-beta") == nil && HermesRuntime.parse(nil) == nil)
    #expect(HermesRuntime.parse(["model": "bad\u{7}id"]) == nil)
    #expect(HermesRuntime(model: "lab-one/model-beta", provider: "Lab-One").matches(provider: "lab-one", model: "model-beta"))
    #expect(!HermesRuntime(model: "model-beta", provider: nil).matches(provider: "lab-one", model: "model-beta"), "no provider is no proof")
    #expect(!HermesRuntime(model: "model-alpha", provider: "lab-one").matches(provider: "lab-one", model: "model-beta"))
}

// MARK: Stream

@Test(arguments: CatalogShape.allCases) @MainActor func theStreamRecordsWhatTheTurnRanOn(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, _, state, _) = applyStore(shape)
    jarvis.modelSettings = .init(conversation: .choice(beta))
    try await sendAndWait(store, jarvis, "hi E2E-RAN")
    #expect(await store.lastRuntime(for: jarvis) == HermesRuntime(model: "model-beta", provider: "lab-one"))
    try await sendAndWait(store, dmt, "hi E2E-PLAIN")
    #expect(await store.lastRuntime(for: dmt) == HermesRuntime(model: "model-alpha", provider: "lab-one"), "an unlocked chat runs the box default")
    #expect(!state.requests().contains { $0.method == "POST" && $0.path.hasPrefix("/p/grok-dmt/") && $0.path.hasSuffix("/model") })
}

@Test(arguments: [E2EServer.RuntimeShape.empty, .absent, .wrongTypes]) @MainActor func noUsableRuntimeMeansNoStateNeverAnError(shape: E2EServer.RuntimeShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(.v0217)
    state.with { $0.runtimeShape = shape }
    try await sendAndWait(store, jarvis, "hi E2E-EMPTY")
    #expect(await store.lastRuntime(for: jarvis) == nil)
    #expect(store.errorMessage == nil && jarvis.messages.last?.content == "E2E-EMPTY")
}

// MARK: Overview

@Test func ranOnLineAndMismatch() {
    let options = HermesModelOptions.parse(catalogPayload(.v0205))
    let lock = HermesModelLock(sessionID: "s1", provider: "lab-one", model: "model-beta", origin: .bot)
    let same = ModelRolesModel.ranOn(.init(model: "model-beta", provider: "lab-one"), lock: lock, sessionID: "s1", options: options)
    #expect(same == .init(line: "Last turn ran on model-beta · Lab One", mismatch: nil))
    let other = ModelRolesModel.ranOn(.init(model: "model-alpha", provider: "lab-one"), lock: lock, sessionID: "s1", options: options)
    #expect(other?.mismatch == "Ran on model-alpha, not the model-beta you chose.")
    #expect(ModelRolesModel.ranOn(.init(model: "model-alpha", provider: "lab-one"), lock: lock, sessionID: "s2", options: options)?.mismatch == nil,
            "a lock recorded for another session says nothing about this one")
    #expect(ModelRolesModel.ranOn(.init(model: "model-alpha", provider: nil), lock: nil, sessionID: "s1", options: nil)?.line == "Last turn ran on model-alpha")
    #expect(ModelRolesModel.ranOn(.init(model: "x", provider: "unlisted"), lock: nil, sessionID: "s1", options: options)?.line == "Last turn ran on x · unlisted")
    #expect(ModelRolesModel.ranOn(nil, lock: lock, sessionID: "s1", options: options) == nil)
    #expect(ModelRolesModel.boxDefaultNote(options) == "Hermes can't unpin a chat; this pins it to the agent's current default (model-alpha).")
    #expect(ModelRolesModel.boxDefaultNote(nil) == nil)
}

@Test(arguments: CatalogShape.allCases) @MainActor func useTheBoxDefaultInsteadSendsOneLockToTheDefaultPair(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    jarvis.modelSettings = .init(conversation: .choice(beta))
    try await sendAndWait(store, jarvis, "hi E2E-BACK")
    state.with { $0.runtimeModel = "model-gamma" }
    try await sendAndWait(store, jarvis, "again E2E-BACK")
    let runtime = await store.lastRuntime(for: jarvis)
    let options = store.botInfo.info(for: jarvis.id)?.modelOptions.value
    #expect(ModelRolesModel.ranOn(runtime, lock: jarvis.hermesModelLock, sessionID: jarvis.hermesSessionID, options: options)?.mismatch
        == "Ran on model-gamma, not the model-beta you chose.")
    #expect(lockPosts(state).count == 1)
    await store.useBoxDefault(for: jarvis)
    let posts = lockPosts(state)
    try #require(posts.count == 2, "one more lock, to the default pair")
    #expect(posts[1].path == "/p/grok-jarvis/api/sessions/\(sessionOf(jarvis))/model")
    #expect(posts[1].body["model"] as? String == "model-alpha" && posts[1].body["provider"] as? String == "lab-one" && Set(posts[1].body.keys) == ["model", "provider"])
    #expect(jarvis.hermesModelLock?.model == "model-alpha" && store.botInfo.info(for: jarvis.id)?.modelError == nil)
}

// MARK: --e2e --roles

@Test func rolesArgumentsNeedTwoPairs() {
    #expect(HeadlessE2E.rolePairs(arguments: ["app", "--e2e"]) == nil)
    let ok = HeadlessE2E.rolePairs(arguments: ["app", "--e2e", "--roles", "lab-one/model-alpha", "router/relay/model-1"])
    #expect(ok == .success(.init(conversation: alpha, coding: ModelChoice(provider: "router", model: "relay/model-1")!)))
    for bad in [["--roles"], ["--roles", "lab-one/model-alpha"], ["--roles", "lab-one/model-alpha", "--other"], ["--roles", "model-alpha", "lab-one/model-beta"],
                ["--roles", "lab-one/", "lab-one/model-beta"], ["--roles", "lab-one/model\u{7}", "lab-one/model-beta"]] {
        #expect(HeadlessE2E.rolePairs(arguments: ["app", "--e2e"] + bad) == .failure(.init()), "\(bad)")
    }
}

@MainActor @Test func e2eRolesAppendsStepGInSelfTestSessions() async throws {
    let (store, bots, state) = e2eStore()
    let pairs = HeadlessE2E.RolePairs(conversation: ModelChoice(provider: "prov", model: "model-b")!, coding: ModelChoice(provider: "prov", model: "model-a")!)
    var output: [String] = []
    let steps = await HeadlessE2E.run(store: store, bots: bots, timing: .fast, roles: pairs, output: { output.append($0) })
    #expect(steps.map(\.id) == ["a", "b1", "b2", "c", "d", "e", "f", "g1", "g2"])
    #expect(steps.allSatisfy { $0.passed }, "\(output)")
    #expect(output.last == "E2E: 9 passed, 0 failed")
    #expect(steps[7].detail.contains("runtime prov/model-b") && steps[8].detail.contains("runtime prov/model-a"))

    let roleBot = try #require(store.bots.first { $0.name.hasSuffix(" roles") })
    let session = try #require(roleBot.hermesSessionID), fork = try #require(roleBot.threads.first?.hermesSessionID)
    let prefix = "/p/grok-jarvis/api/sessions"
    let calls = state.requests().map { "\($0.method) \($0.path)" }.filter { $0.contains(session) || $0.contains(fork) || $0 == "POST \(prefix)" }
    let start = try #require(calls.lastIndex(of: "POST \(prefix)"))
    #expect(Array(calls[start...]) == ["POST \(prefix)", "GET \(prefix)/\(session)", "POST \(prefix)/\(session)/model", "POST \(prefix)/\(session)/chat/stream",
                                       "GET \(prefix)/\(session)", "GET \(prefix)/\(session)", "POST \(prefix)/\(session)/fork", "POST \(prefix)/\(fork)/model",
                                       "POST \(prefix)/\(fork)/chat/stream"], "Part D: g2 runs Code in thread, which re-reads the list for this chat before it forks")
    #expect(AppConstants.isSelfTestSession(session) && AppConstants.isSelfTestSession(fork))
    #expect(roleBot.threads.first?.role == .coding && roleBot.threads.first?.modelLock?.origin == .coding)
    let inputs = state.requests().filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["input"] as? String ?? "" }
    #expect(inputs.count == 9 && inputs.allSatisfy { $0.contains(HeadlessE2E.preamble) })
    #expect(state.requests().filter { $0.path.hasSuffix("/chat/stream") }.allSatisfy { Set($0.body?.keys ?? [:].keys) == ["input", "instructions"] })
}

@MainActor @Test func e2eRolesFailsWhenTheTurnRanOnSomethingElse() async throws {
    let (store, bots, state) = e2eStore()
    state.with { $0.runtimeModel = "model-z" }
    let pairs = HeadlessE2E.RolePairs(conversation: ModelChoice(provider: "prov", model: "model-b")!, coding: ModelChoice(provider: "prov", model: "model-a")!)
    var output: [String] = []
    let steps = await HeadlessE2E.run(store: store, bots: bots, timing: .fast, roles: pairs, output: { output.append($0) })
    #expect(steps.filter { !$0.passed }.map(\.id) == ["g1", "g2"], "\(output)")
    #expect(output.contains { $0.hasPrefix("FAIL g1 conversation role") && $0.contains("runtime prov/model-z") })
    #expect(output.last == "E2E: 7 passed, 2 failed")
}

@MainActor @Test func e2eRolesRefusesACodingPairTheProfileDoesNotOffer() async throws {
    let (store, bots, state) = e2eStore()
    let pairs = HeadlessE2E.RolePairs(conversation: ModelChoice(provider: "prov", model: "model-b")!, coding: ModelChoice(provider: "prov", model: "model-q")!)
    let steps = await HeadlessE2E.run(store: store, bots: bots, timing: .fast, roles: pairs, output: { _ in })
    #expect(steps.last?.passed == false && steps.last?.detail.contains("model-q isn't offered by this agent.") == true)
    #expect(state.requests().filter { $0.path.hasSuffix("/fork") }.count == 1, "only step c forks; g2 stops before its fork")
    #expect(lockPosts(state).allSatisfy { $0.body["model"] as? String != "model-q" })
}

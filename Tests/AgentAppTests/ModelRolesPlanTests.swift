import Foundation
import Testing
@testable import AgentApp

// P13 Part D, "Switch existing chats…": every skip reason, hand picks kept, the streaming bot skipped, the per-bot
// catalog check, nothing sent before Confirm, one lock per bot and partial failure. Synthetic data only.

private let alpha = ModelChoice(provider: "lab-one", model: "model-alpha")!
private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private let unlisted = ModelChoice(provider: "lab-one", model: "model-unlisted")!
private func sessionOf(_ bot: Bot) -> String { "agentapp_\(bot.id.uuidString.lowercased())" }

private func input(_ shape: CatalogShape, _ configure: (inout ModelRolesPlan.Input) -> Void = { _ in }) -> ModelRolesPlan.Input {
    let catalog = HermesModelOptions.parse(catalogPayload(shape)).catalog(profile: "grok-jarvis")
    var input = ModelRolesPlan.Input(id: UUID(), name: "Jarvis", sessionID: "s1", current: .init(model: "model-alpha", provider: nil, source: CurrentModel.agentDefault),
                                     catalog: .loaded(catalog), defaults: .init(conversation: beta))
    configure(&input)
    return input
}

@Test(arguments: CatalogShape.allCases) func planRowsSayFromToOrWhyEachBotIsSkipped(shape: CatalogShape) {
    let change = ModelRolesPlan.row(input(shape))
    #expect(change.willChange && change.text == "model-alpha → model-beta" && change.origin == .torvliDefault && change.to == beta)
    let cases: [(String, ModelRolesPlan.Input, ModelRolesPlan.Skip, String)] = [
        ("already", input(shape) { $0.defaults = .init(conversation: alpha) }, .alreadyOn, "already on it"),
        ("no session", input(shape) { $0.sessionID = nil }, .noSession, "no chat yet; a new chat starts on its model"),
        ("hand pick", input(shape) { $0.lock = HermesModelLock(sessionID: "s1", provider: "lab-one", model: "model-alpha") }, .handPick("model-alpha"),
         "keeps the model you picked (model-alpha)"),
        ("not offered", input(shape) { $0.settings = .init(conversation: .choice(unlisted)) }, .notOffered(ModelRoleReason.notOffered("model-unlisted").text + " A new chat stops until you change it."),
         "model-unlisted isn't offered by this agent. A new chat stops until you change it."),
        ("no lock", input(shape) { $0.blocker = .noLock }, .cannotSwitch(ModelRoleReason.noLock.text), ModelRoleReason.noLock.text),
        ("no key", input(shape) { $0.block = ModelCatalog.noKey }, .cannotSwitch(ModelCatalog.noKey), ModelCatalog.noKey),
        ("streaming", input(shape) { $0.isStreaming = true }, .streaming, "is answering; try again when it is done"),
        ("not loaded", input(shape) { $0.catalog = .loading }, .notLoaded, "models not loaded; press Load first"),
        ("failed", input(shape) { $0.catalog = .failed("HTTP 500") }, .cannotSwitch("HTTP 500"), "HTTP 500"),
    ]
    for (name, input, skip, text) in cases {
        let row = ModelRolesPlan.row(input)
        #expect(row.skip == skip && row.text == text && !row.willChange, "\(name): \(row)")
    }
    // A lock the app recorded (any origin) is moved; one on an older session does not count as a hand pick.
    let recorded = ModelRolesPlan.row(input(shape) { $0.lock = HermesModelLock(sessionID: "s1", provider: "lab-one", model: "model-alpha", origin: .bot) })
    let oldSession = ModelRolesPlan.row(input(shape) { $0.lock = HermesModelLock(sessionID: "s0", provider: "lab-one", model: "model-gamma") })
    #expect(recorded.willChange && oldSession.willChange)
    // A default this agent lacks falls to the agent default, as a new chat would: nothing to change here.
    #expect(ModelRolesPlan.row(input(shape) { $0.defaults = .init(conversation: unlisted) }).skip == .alreadyOn)
    let plan = ModelRolesPlan([input(shape), input(shape) { $0.sessionID = nil }, input(shape) { $0.isStreaming = true }])
    #expect(plan.countText == "1 of 3 would change" && plan.changing.count == 1)
}

@Test func lockTargetFollowsTheResolvedPairElseTheAgentDefaultPair() {
    let catalog = HermesModelOptions.parse(catalogPayload(.v0205)).catalog(profile: "grok-jarvis")
    #expect(ModelPolicy.lockTarget(settings: nil, defaults: .init(conversation: beta), catalog: catalog) == .pair(beta, .torvliDefault))
    #expect(ModelPolicy.lockTarget(settings: .init(conversation: .choice(beta)), defaults: nil, catalog: catalog) == .pair(beta, .bot))
    #expect(ModelPolicy.lockTarget(settings: .init(conversation: .box), defaults: .init(conversation: beta), catalog: catalog) == .pair(alpha, .bot))
    #expect(ModelPolicy.lockTarget(settings: nil, defaults: nil, catalog: catalog) == .pair(alpha, nil))
    #expect(ModelPolicy.lockTarget(settings: nil, defaults: nil, catalog: nil) == .refused(ModelRoleReason.noList.text))
}

/// Jarvis, DMT and Achilles each with a started, unlocked main chat; then the default moves to model-beta.
@MainActor private func startedStore(_ shape: CatalogShape) async throws -> (store: AppStore, jarvis: Bot, dmt: Bot, achilles: Bot, state: E2EServer.State) {
    let (store, jarvis, dmt, achilles, state, _) = applyStore(shape)
    for bot in [jarvis, dmt, achilles] { try await sendAndWait(store, bot, "hi E2E-START") }
    #expect(lockPosts(state).isEmpty, "inert until configured")
    store.modelDefaults.conversation = beta
    return (store, jarvis, dmt, achilles, state)
}

@Test(arguments: CatalogShape.allCases) @MainActor func switchExistingChatsSendsNothingBeforeConfirmThenOneLockPerBot(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, achilles, state) = try await startedStore(shape)
    #expect(store.modelRolesPlan().rows.allSatisfy { $0.skip == .notLoaded }, "the preview reads only the cache")
    await store.loadModelRoles()
    let mark = state.requests().count
    let plan = store.modelRolesPlan()
    #expect(plan.countText == "3 of 3 would change" && plan.rows.map(\.text) == Array(repeating: "model-alpha → model-beta", count: 3))
    #expect(state.requests().count == mark, "nothing is sent before Confirm")

    state.with { $0.lockFailures[sessionOf(dmt)] = 500 }
    let results = await store.runModelRolesPlan(plan)
    #expect(lines(state, from: mark) == [jarvis, dmt, achilles].map { "POST /p/\($0.hermesProfile!)/api/sessions/\(sessionOf($0))/model" }, "one at a time, in order")
    #expect(lockPosts(state).allSatisfy { Set($0.body.keys) == ["model", "provider"] && $0.body["model"] as? String == "model-beta" })
    #expect(results[jarvis.id] == "switched to model-beta" && results[achilles.id] == "switched to model-beta")
    let failure = try #require(results[dmt.id])
    #expect(failure.hasPrefix("failed: ") && failure.contains("[key]") && !failure.contains("dmt-key-88"), "a failure never stops the rest: \(failure)")
    #expect(jarvis.hermesModelLock == HermesModelLock(sessionID: sessionOf(jarvis), provider: "lab-one", model: "model-beta", origin: .torvliDefault))
    #expect(dmt.hermesModelLock == nil && achilles.hermesModelLock?.origin == .torvliDefault)
    #expect(jarvis.threads.isEmpty && store.groups.isEmpty, "main chats only")
    #expect(store.modelRolesPlan().countText == "1 of 3 would change", "only the failed bot is left")
}

@Test(arguments: CatalogShape.allCases) @MainActor func switchExistingChatsKeepsHandPicksAndSkipsTheStreamingBot(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, achilles, state) = try await startedStore(shape)
    await store.loadModelRoles()
    jarvis.hermesModelLock = HermesModelLock(sessionID: sessionOf(jarvis), provider: "lab-one", model: "model-alpha")
    dmt.messages.append(ChatMessage(role: .assistant, content: "", isStreaming: true))
    let plan = store.modelRolesPlan()
    #expect(plan.rows.map(\.skip) == [.handPick("model-alpha"), .streaming, nil])
    let mark = state.requests().count
    let results = await store.runModelRolesPlan(plan)
    #expect(lines(state, from: mark) == ["POST /p/grok-achilles/api/sessions/\(sessionOf(achilles))/model"])
    #expect(results.count == 1 && jarvis.hermesModelLock?.origin == nil && jarvis.hermesModelLock?.model == "model-alpha")
}

@Test(arguments: CatalogShape.allCases) @MainActor func switchExistingChatsChecksEachBotsOwnCatalogAndRechecksBeforeEachPost(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, achilles, state, _) = applyStore(shape)
    state.with { $0.catalogs["grok-dmt"] = soloCatalogPayload() }
    for bot in [jarvis, dmt, achilles] { try await sendAndWait(store, bot, "hi E2E-START") }
    store.modelDefaults.conversation = beta
    achilles.modelSettings = .init(conversation: .choice(unlisted))
    await store.loadModelRoles()
    let plan = store.modelRolesPlan()
    #expect(plan.rows.map(\.skip) == [nil, .alreadyOn, .notOffered(ModelRoleReason.notOffered("model-unlisted").text + " A new chat stops until you change it.")],
            "DMT's profile lacks model-beta, so its chats stay on its agent default")
    // The preview moved on before Confirm: Jarvis now runs model-beta, so nothing is sent for it.
    jarvis.modelSettings = .init(conversation: .box)
    let mark = state.requests().count
    let results = await store.runModelRolesPlan(plan)
    #expect(state.requests().count == mark && results[jarvis.id] == "already on it")
}

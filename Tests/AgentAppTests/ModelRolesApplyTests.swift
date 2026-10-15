import Foundation
import Testing
@testable import AgentApp

// P13 Part B: the Conversation role applied when the app starts a chat. Every test runs against the 0.20.5- and
// the 0.21.x-shaped catalog. Synthetic gateway (`E2EServer` via `applyStore`); no real names.

private let alpha = ModelChoice(provider: "lab-one", model: "model-alpha")!
private let beta = ModelChoice(provider: "lab-one", model: "model-beta")!
private let routed = ModelChoice(provider: "router", model: "relay/model-1")!
private func sessionOf(_ bot: Bot) -> String { "agentapp_\(bot.id.uuidString.lowercased())" }
private func notes(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }

@Test(arguments: CatalogShape.allCases) @MainActor func firstSendCreatesThenReadsTheRowThenLocksThenChats(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, url) = applyStore(shape)
    store.modelDefaults.conversation = beta
    await store.loadServerInfo(for: jarvis, includeSkills: false)
    let mark = state.requests().count
    try await sendAndWait(store, jarvis, "hello E2E-ONE")
    let session = sessionOf(jarvis), prefix = "/p/grok-jarvis/api/sessions"
    #expect(lines(state, from: mark).filter { !$0.hasSuffix("/v1/capabilities") } == ["POST \(prefix)", "GET \(prefix)/\(session)", "POST \(prefix)/\(session)/model", "POST \(prefix)/\(session)/chat/stream"])
    let requests = state.requests()
    #expect(Set(requests.first { $0.path == prefix }?.body?.keys ?? [:].keys) == ["title", "system_prompt", "source", "id"], "create body unchanged")
    let lock = try #require(lockPosts(state).first)
    #expect(Set(lock.body.keys) == ["model", "provider"])
    #expect(lock.body["model"] as? String == "model-beta" && lock.body["provider"] as? String == "lab-one")
    #expect(Set(requests.last?.body?.keys ?? [:].keys) == ["input", "instructions"], "the chat body carries no model")
    #expect(jarvis.hermesModelLock == HermesModelLock(sessionID: session, provider: "lab-one", model: "model-beta", origin: .torvliDefault))
    #expect(jarvis.hermesSessionID == session && notes(jarvis).isEmpty)
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(saved.contains(#""modelDefaults":{"#) && !saved.contains("Lab One"), "slug and id strings only")
    for key in applyKeys.values { #expect(!saved.contains(key) && !requests.contains { ($0.body.map { "\($0)" } ?? "").contains(key) }) }
}

@Test(arguments: CatalogShape.allCases) @MainActor func precedenceAcrossThreeBots(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, achilles, state, _) = applyStore(shape)
    store.modelDefaults.conversation = alpha
    jarvis.modelSettings = .init(conversation: .choice(routed)); dmt.modelSettings = .init(conversation: .box)
    for bot in [jarvis, dmt, achilles] { try await sendAndWait(store, bot, "hi E2E-PRECEDENCE") }
    #expect(lockPosts(state).map(\.path) == ["/p/grok-jarvis/api/sessions/\(sessionOf(jarvis))/model", "/p/grok-achilles/api/sessions/\(sessionOf(achilles))/model"])
    #expect(jarvis.hermesModelLock?.model == "relay/model-1" && jarvis.hermesModelLock?.origin == .bot)
    #expect(dmt.hermesModelLock == nil && !lines(state).contains { $0.contains("grok-dmt/api/model/options") }, "an opt-out is inert")
    #expect(achilles.hermesModelLock?.model == "model-alpha" && achilles.hermesModelLock?.origin == .torvliDefault)
    #expect(store.modelRolesSummary(for: jarvis).hasPrefix("Jarvis: roles conversation relay/model-1 (this bot)"))
    #expect(store.modelRolesSummary(for: achilles).hasPrefix("Achilles: roles conversation model-alpha (\(AppConstants.name) default)"))
}

@Test(arguments: CatalogShape.allCases) @MainActor func refusedDefaultSendsOnTheBoxDefaultWithANote(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    store.modelDefaults.conversation = beta
    state.with { $0.lockStatus = 409 }
    try await sendAndWait(store, jarvis, "hi E2E-DEFAULT")
    let note = "\(AppConstants.name)'s default model model-beta was not applied: Hermes cannot route model-beta for this chat and will not fall back to the default. This chat runs on the agent default."
    #expect(notes(jarvis) == [note])
    #expect(store.botInfo.info(for: jarvis.id)?.modelError == note)
    #expect(jarvis.hermesModelLock == nil && jarvis.hermesSessionID == sessionOf(jarvis))
    #expect(lines(state).last == "POST /p/grok-jarvis/api/sessions/\(sessionOf(jarvis))/chat/stream")
    #expect(jarvis.messages.last?.content == "E2E-DEFAULT", "the note sits before the reply")
}

@Test(arguments: CatalogShape.allCases) @MainActor func refusedOverrideStopsTheSendAndTheNextSendRetries(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    jarvis.modelSettings = .init(conversation: .choice(beta))
    state.with { $0.lockStatus = 409 }
    try await sendAndWait(store, jarvis, "hi E2E-OVERRIDE")
    #expect(!lines(state).contains { $0.hasSuffix("/chat/stream") }, "nothing was sent")
    #expect(jarvis.hermesSessionID == nil && jarvis.hermesModelLock == nil)
    #expect(store.errorMessage == "model-beta, this bot's model, was not applied: Hermes cannot route model-beta for this chat and will not fall back to the default. Nothing was sent.")

    state.with { $0.lockStatus = 200; $0.existingSessions = [sessionOf(jarvis)] }
    let mark = state.requests().count
    try await sendAndWait(store, jarvis, "again E2E-RETRY")
    let prefix = "/p/grok-jarvis/api/sessions", session = sessionOf(jarvis)
    #expect(lines(state, from: mark).filter { !$0.hasSuffix("/v1/capabilities") && !$0.hasSuffix("/api/model/options") }
        == ["POST \(prefix)", "GET \(prefix)/\(session)", "POST \(prefix)/\(session)/model", "POST \(prefix)/\(session)/chat/stream"])
    #expect(jarvis.hermesModelLock?.origin == .bot && jarvis.hermesSessionID == session)
}

@Test(arguments: CatalogShape.allCases) @MainActor func anExistingSessionWithAConcreteModelKeepsIt(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    jarvis.modelSettings = .init(conversation: .choice(beta))
    state.with { $0.existingSessions = [sessionOf(jarvis)]; $0.sessionModels[sessionOf(jarvis)] = "model-alpha" }
    try await sendAndWait(store, jarvis, "hi E2E-EXISTS")
    #expect(lockPosts(state).isEmpty && jarvis.hermesModelLock == nil && notes(jarvis).isEmpty)
    #expect(lines(state).last?.hasSuffix("/chat/stream") == true)
}

@Test(arguments: CatalogShape.allCases) @MainActor func gatesSendNoLockAndSayWhy(shape: CatalogShape) async throws {
    let cases: [(String, [String: Bool], (E2EServer.State) -> Void, ModelChoice, String)] = [
        ("lock off", applyFeatures.merging(["session_model_lock": false]) { $1 }, { _ in }, beta, ModelRoleReason.noLock.text),
        ("options off", applyFeatures.merging(["model_options": false]) { $1 }, { _ in }, beta, ModelRoleReason.noList.text),
        ("options 404", applyFeatures, { $0.optionsStatus = 404 }, beta, ModelRoleReason.noList.text),
        ("options 405", applyFeatures, { $0.optionsStatus = 405 }, beta, ModelRoleReason.noList.text),
        ("no session read", applyFeatures.merging(["session_resources": false]) { $1 }, { _ in }, beta, ModelRoleReason.noRow.text),
        ("unlisted", applyFeatures, { _ in }, ModelChoice(provider: "lab-one", model: "model-unlisted")!, ModelRoleReason.notOffered("model-unlisted").text),
    ]
    for (name, features, configure, choice, reason) in cases {
        let (store, jarvis, _, _, state, _) = applyStore(shape, features: features)
        state.with(configure)
        store.modelDefaults.conversation = choice
        try await sendAndWait(store, jarvis, "hi E2E-GATE")
        #expect(lockPosts(state).isEmpty, "\(name)")
        #expect(notes(jarvis).first?.contains(reason) == true, "\(name): \(notes(jarvis))")
        #expect(lines(state).last?.hasSuffix("/chat/stream") == true, "\(name): a default never bricks a bot")
    }
    // Legacy transport: no sessions, so nothing is created or locked; the pane says why.
    let (store, jarvis, _, _, state, _) = applyStore(shape, features: applyFeatures.merging(["session_chat_streaming": false]) { $1 })
    store.modelDefaults.conversation = beta
    store.selectedBot = jarvis; _ = store.send(text: "hi"); try await waitUntil { store.isIdle }
    #expect(lockPosts(state).isEmpty && !lines(state).contains("POST /p/grok-jarvis/api/sessions"))
    await store.loadServerInfo(for: jarvis)
    #expect(store.modelRolesRow(for: jarvis).blocked == .legacy)
}

@Test(arguments: CatalogShape.allCases) @MainActor func groupMembersUseTheirOwnSettings(shape: CatalogShape) async throws {
    let (store, jarvis, dmt, _, state, _) = applyStore(shape)
    jarvis.modelSettings = .init(conversation: .choice(beta))
    let group = try #require(store.createGroup(name: "Lab", memberIDs: [jarvis.id, dmt.id]))
    #expect(store.send(text: "hi E2E-GROUP", to: group)); try await waitUntil { store.isIdle }
    let jarvisSession = try #require(group.session(for: jarvis.id))
    #expect(lockPosts(state).map(\.path) == ["/p/grok-jarvis/api/sessions/\(jarvisSession)/model"])
    #expect(jarvis.hermesModelLock == nil, "a group session's lock is not the main chat's")

    state.with { $0.lockStatus = 409 }
    let second = try #require(store.createGroup(name: "Lab 2", memberIDs: [jarvis.id, dmt.id]))
    #expect(store.send(text: "again E2E-SKIP", to: second)); try await waitUntil { store.isIdle }
    #expect(second.messages.contains { $0.role == .system && $0.content.hasPrefix("Jarvis was skipped: model-beta, this bot's model, was not applied") })
    #expect(second.session(for: jarvis.id) == nil && second.messages.last?.authorID == dmt.id, "the other member still answers")
}

@Test(arguments: CatalogShape.allCases) @MainActor func switchThisChatSendsOneLockWithItsOrigin(shape: CatalogShape) async throws {
    let (store, jarvis, _, _, state, _) = applyStore(shape)
    jarvis.hermesSessionID = "s1"; state.with { $0.sessionModels["s1"] = "model-alpha" }
    jarvis.modelSettings = .init(conversation: .choice(beta))
    await store.loadServerInfo(for: jarvis)
    let row = store.modelRolesRow(for: jarvis)
    #expect(row.mismatch == "This chat runs model-alpha; this bot's default is model-beta." && row.canSwitch && row.switchNote == nil)
    await store.switchChatToRoleModel(for: jarvis)
    #expect(lockPosts(state).count == 1 && lockPosts(state)[0].body["model"] as? String == "model-beta")
    #expect(jarvis.hermesModelLock == HermesModelLock(sessionID: "s1", provider: "lab-one", model: "model-beta", origin: .bot))
    #expect(store.modelRolesRow(for: jarvis).mismatch == nil)

    // Opting out on a pinned chat re-pins it to the box's current default.
    jarvis.modelSettings = .init(conversation: .box)
    #expect(store.modelRolesRow(for: jarvis).switchNote == "Hermes can't unpin a chat; this pins it to the agent's current default (model-alpha).")
    await store.switchChatToRoleModel(for: jarvis)
    #expect(lockPosts(state).count == 2 && jarvis.hermesModelLock?.model == "model-alpha" && jarvis.hermesModelLock?.provider == "lab-one")
}

@Test @MainActor func nothingConfiguredSendsNothingExtra() async throws {
    let (store, jarvis, _, _, state, url) = applyStore(.v0205)
    try await sendAndWait(store, jarvis, "hi E2E-INERT")
    let prefix = "/p/grok-jarvis/api/sessions", session = sessionOf(jarvis)
    #expect(lines(state) == ["GET /p/grok-jarvis/v1/capabilities", "POST \(prefix)", "POST \(prefix)/\(session)/chat/stream"])
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains("modelDefaults") && !saved.contains("modelSettings") && !saved.contains("origin"))
}

@Test @MainActor func aServerErrorEchoingTheKeyIsRedacted() async throws {
    let (store, jarvis, _, _, state, _) = applyStore(.v0217)
    store.modelDefaults.conversation = beta
    state.with { $0.lockStatus = 500 }
    try await sendAndWait(store, jarvis, "hi E2E-REDACT")
    let note = try #require(notes(jarvis).first)
    #expect(note.contains("[key]") && !note.contains("jarvis-key-77"))
    #expect(store.botInfo.info(for: jarvis.id)?.modelError?.contains("jarvis-key-77") == false)
}

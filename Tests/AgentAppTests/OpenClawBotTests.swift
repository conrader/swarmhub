import Foundation
import Testing
@testable import AgentApp

// P12 Part B: OpenClaw bots in the store, end to end over the fake Gateway.

@MainActor func clawStore(_ fake: FakeGateway = FakeGateway(), bind: Bool = true) -> (AppStore, Bot, OpenClawGateway, InMemoryKeyStore) {
    let defaults = isolatedDefaults(); let (gateway, keys) = fakeGatewaySetup()
    GatewayStore(defaults: defaults, keyStore: keys).upsert(gateway)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults, openClawHub: clawHub(fake, keys: keys))
    let bot = Bot(name: "Alpha", persona: "", backend: .openClaw)
    if bind { bot.openClaw = .init(gatewayID: gateway.id, agentID: "agent-alpha") }
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot, gateway, keys)
}

func echoCreate() -> FakeGateway.Handler { { params, _ in .success(["ok": true, "key": params["key"] ?? .null]) } }

@MainActor @Test func aMessageToAnOpenClawBotStreamsTheAgentsReply() async throws {
    let fake = FakeGateway()
    fake.handlers["sessions.create"] = echoCreate()
    fake.handlers["chat.send"] = { params, socket in
        let key = params["sessionKey"] ?? .null
        socket.push(["type": "event", "event": "chat", "payload": ["runId": "run-1", "sessionKey": key, "seq": 1, "state": "delta", "message": assistant("Hello ")]])
        socket.push(["type": "event", "event": "chat", "payload": ["runId": "run-1", "sessionKey": key, "seq": 2, "state": "final", "message": assistant("Hello from Alpha")]])
        return .success(["runId": "run-1", "status": "started"])
    }
    let (store, bot, _, _) = clawStore(fake)
    #expect(store.send(text: "Reply with exactly: SwarmHub OK"))
    try await waitUntil { store.isIdle }
    #expect(bot.messages.last?.content == "Hello from Alpha" && bot.messages.last?.turnState == .finished)
    #expect(bot.hermesSessionID == "agent:agent-alpha:agentapp-\(bot.id.uuidString.lowercased())")
    #expect(fake.requestsFor("sessions.create").first?["displayName"] == "SwarmHub · Alpha")
}

@MainActor @Test func stopAbortsTheRunAndSaysOpenClaw() async throws {
    let fake = FakeGateway()
    fake.handlers["sessions.create"] = echoCreate()
    fake.handlers["chat.send"] = ackingSend(runId: "run-7")
    let (store, bot, _, _) = clawStore(fake)
    #expect(store.send(text: "long task"))
    try await fake.requestLog.wait { $0.contains("chat.send") }
    try await waitUntil { bot.hermesSessionID != nil }
    let ledger = store.openClawHub.ledger, key = bot.hermesSessionID ?? ""
    try await waitFor { await ledger.active(sessionKey: key) != nil }
    store.stop()
    try await waitUntil { bot.messages.contains { $0.role == .system && $0.content == "Stop requested from OpenClaw." } }
    #expect(fake.requestsFor("chat.abort").first?["runId"] == "run-7")
}

@MainActor @Test func anUnboundOpenClawBotFromAnOldStoreLoadsAndSaysWhatToDo() throws {
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = Bot(name: "Claw", backend: .openClaw)
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(StoreFile(bots: [old], groups: []))) as? [String: Any])
    var bots = try #require(json["bots"] as? [[String: Any]]); bots[0]["openClaw"] = nil; json["bots"] = bots
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let claw = try #require(store.bots.first)
    #expect(claw.backend == .openClaw && claw.openClaw == nil)
    #expect(throws: (any Error).self) { try store.backend(for: claw) }
    #expect((try? store.backend(for: claw)) == nil && store.openClawBlock(claw) == OpenClawBackend.unboundMessage)
    store.selectedBot = claw
    #expect(!store.send(text: "hi") && store.errorMessage == OpenClawBackend.unboundMessage)
    #expect(store.catalogBlock(for: claw) == .openClawStub)
}

@MainActor @Test func theBindingRoundTripsThroughStoreJSON() throws {
    let bot = Bot(name: "Alpha", backend: .openClaw); bot.openClaw = .init(gatewayID: "gw-1", agentID: "agent-alpha", sessionMode: .main)
    let decoded = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
    #expect(decoded.openClaw == bot.openClaw)
    let hermes = Bot(name: "H", backend: .hermes)
    #expect(!String(decoding: try JSONEncoder().encode(hermes), as: UTF8.self).contains("openClaw"), "untouched bots encode as before")
    #expect(BackendKind.openClaw.hasServerSessions && BackendKind.hermes.hasServerSessions && !BackendKind.mock.hasServerSessions)
    #expect(BackendKind.allCases.map(\.shortName) == ["Mock", "Hermes", "OpenClaw"])
}

@MainActor @Test func addBotsIsIdempotentAndNeverRemovesBots() async throws {
    let (store, existing, gateway, _) = clawStore()
    let first = try await store.addBotsFromGateway(gateway)
    #expect(first == [.init(name: "Alpha", added: false), .init(name: "Beta", added: true)], "agent-alpha already has a bot")
    let beta = try #require(store.bots.first { $0.openClaw?.agentID == "agent-beta" })
    #expect(beta.name == "Beta" && beta.title == "OpenClaw agent" && beta.persona.isEmpty && beta.backend == .openClaw && beta.avatarMark != nil)
    let again = try await store.addBotsFromGateway(gateway)
    #expect(again.allSatisfy { !$0.added } && store.bots.count == 2 && store.bots.contains(existing))
}

@MainActor @Test func editorSaveRulesAndBindingChanges() {
    var fields = BotEditorFields(); fields.name = "Claw"; fields.backend = .openClaw
    #expect(!fields.openClawReady)
    fields.openClawGatewayID = "gw-1"; #expect(!fields.openClawReady)
    fields.openClawAgentID = "  agent-alpha "; #expect(fields.openClawReady && fields.openClawBinding == .init(gatewayID: "gw-1", agentID: "agent-alpha"))
    let (store, bot, _, _) = clawStore()
    bot.hermesSessionID = "agent:agent-alpha:old"
    var edit = BotEditorFields(bot: bot)
    #expect(edit.openClawGatewayID == bot.openClaw?.gatewayID && edit.openClawAgentID == "agent-alpha")
    edit.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.hermesSessionID == "agent:agent-alpha:old", "an unchanged binding keeps the session")
    edit.openClawAgentID = "agent-beta"; edit.apply(to: bot, store: store, avatarTouched: false)
    #expect(bot.openClaw?.agentID == "agent-beta" && bot.hermesSessionID == nil, "another agent starts a new session")
    var hermes = BotEditorFields(); hermes.backend = .hermes; hermes.name = "H"
    #expect(hermes.openClawReady && hermes.openClawBinding == nil)
}

@MainActor @Test func theBannerBlocksWhatCannotSendAndLetsConnectingWait() {
    let (store, bot, gateway, _) = clawStore()
    let status = store.openClawStatus
    #expect(store.openClawBlock(bot) == nil && store.openClawNotice(bot) == nil, "never connected: a send connects")
    status.set(.connecting, for: gateway.id)
    #expect(store.openClawBlock(bot) == nil && store.openClawNotice(bot) == "Connecting…")
    status.set(.pairingRequired(requestId: "req-3", reason: nil, deviceId: "d"), for: gateway.id)
    #expect(store.openClawBlock(bot) == "Waiting for approval on the Gateway host: openclaw devices approve req-3")
    status.set(.failed(.tokenRejected), for: gateway.id)
    #expect(store.openClawBlock(bot) == "The Gateway rejected the token. Paste the current one.")
    var readOnly = GatewaySummary(protocolVersion: 4, serverVersion: "2026.10.3"); readOnly.scopes = ["operator.read"]
    status.set(.connected(readOnly), for: gateway.id)
    #expect(store.openClawBlock(bot) == "This Mac is paired read-only (needs operator.write).")
    readOnly.scopes = OpenClawClient.scopes; status.set(.connected(readOnly), for: gateway.id)
    #expect(store.openClawBlock(bot) == nil)
    let hermes = Bot(name: "H", backend: .hermes)
    #expect(store.openClawBlock(hermes) == nil)
}

@MainActor @Test func openClawBotsStayOutOfGroupPickersAndForgetUnbindsButKeepsThem() async {
    let (store, bot, gateway, keys) = clawStore()
    #expect(!bot.joinsGroups && Bot(name: "H", backend: .hermes).joinsGroups && Bot(name: "M", backend: .mock).joinsGroups)
    keys.setKey("device-token-x", for: gateway.deviceTokenAccount)
    await store.forgetGateway(gateway)
    #expect(store.bots == [bot] && bot.openClaw == nil && store.openClawGateways.isEmpty && keys.all().isEmpty)
}

@MainActor @Test func hermesOnlyFeaturesStayHermesOnly() async {
    let (store, bot, _, _) = clawStore()
    #expect(!store.needsKey(bot) && !store.isManager(bot))
    #expect(await store.refreshRoutines(for: bot) == true)
    #expect(!store.routines.state(for: bot.id).hasJobsAPI)
    #expect(store.canFork(bot) == false, "no session yet")
}

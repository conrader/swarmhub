import Foundation
import Testing
@testable import AgentApp

// P12 Part C: secrets stay in the Keychain (and the one connect frame that must carry the credential); history
// comparison normalises OpenClaw's directives; the Overview says what the link can do.

@MainActor @Test func theTokenDeviceTokenAndPrivateKeyAppearNowhereElse() async throws {
    let shared = "SENTINEL-SHARED-0001"
    let fake = FakeGateway(); fake.sharedToken = shared
    fake.handlers["sessions.create"] = echoCreate()
    fake.handlers["chat.send"] = { params, socket in
        socket.push(["type": "event", "event": "chat", "payload": ["runId": "run-1", "sessionKey": params["sessionKey"] ?? .null, "seq": 1, "state": "final", "message": assistant("ok")]])
        return .success(["runId": "run-1"])
    }
    let defaults = isolatedDefaults(); var (gateway, keys) = fakeGatewaySetup(token: shared, keepsToken: true)
    gateway.name = "Sentinel Gateway"
    GatewayStore(defaults: defaults, keyStore: keys).upsert(gateway)
    let hub = clawHub(fake, keys: keys)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults, openClawHub: hub)
    let bot = Bot(name: "Alpha", persona: "", backend: .openClaw); bot.openClaw = .init(gatewayID: gateway.id, agentID: "agent-alpha")
    store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "hello"))
    try await waitUntil { !store.anyTurnRunning }
    store.save()

    let deviceToken = keys.key(for: gateway.deviceTokenAccount), privateKey = keys.key(for: gateway.deviceKeyAccount)
    let privateHex = try #require(Data(base64Encoded: privateKey)).map { String(format: "%02x", $0) }.joined()
    let secrets = [shared, deviceToken, privateKey, privateHex]
    #expect(!deviceToken.isEmpty && !privateKey.isEmpty && bot.messages.last?.content == "ok")

    var lines: [String] = []
    _ = await HeadlessOpenClaw.check(gateways: [gateway], hub: hub, output: { lines.append($0) })
    var bad = OpenClawGateway(name: "Bad", url: "ws://127.0.0.1:1"); bad.keepsToken = true
    keys.setKey(shared, for: bad.tokenAccount)
    let failingHub = OpenClawHub(status: OpenClawStatus(), keyStore: keys, makeTransport: {
        let transport = ScriptedGatewayTransport(server: nil); transport.openError = BackendError.unavailable("refused with \(shared)"); return transport
    })
    let tested = try? await failingHub.test(bad)
    let badState = await failingHub.state(bad.id)
    let failure = tested ?? GatewayRedactor.redact(badState.line(), secrets: secrets)
    let texts = [String(reflecting: store.bots), String(reflecting: store.openClawGateways), String(reflecting: store.openClawStatus.states),
                 String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self), "\(defaults.dictionaryRepresentation())",
                 lines.joined(separator: "\n"), failure, store.errorMessage ?? ""]
    for text in texts { for secret in secrets { #expect(!text.contains(secret), "a secret leaked into: \(text.prefix(120))") } }
    #expect(lines.first?.hasPrefix("Sentinel Gateway | ws://127.0.0.1:18789 | connected | 2026.10.3 | protocol 4") == true)

    // Frames: only `connect` carries the credential; the private key is in none.
    let frames = fake.connectParams.map(\.jsonText) + fake.requestsFor("chat.send").map(\.jsonText) + fake.requestsFor("sessions.create").map(\.jsonText)
    #expect(frames.allSatisfy { !$0.contains(privateKey) && !$0.contains(privateHex) })
    #expect(fake.requestsFor("chat.send").allSatisfy { !$0.jsonText.contains(shared) && !$0.jsonText.contains(deviceToken) })
}

@MainActor @Test func historyComparisonNormalisesDirectivesAndNoReplyOnBothSides() {
    #expect(AppStore.sameText("Done", "[[reply_to_current]] Done") && AppStore.sameText("NO_REPLY", ""))
    #expect(!AppStore.sameText("Done", "Not done"))
    let local = [ChatMessage(role: .user, content: "q"), ChatMessage(role: .assistant, content: "Done")]
    let server = [BackendMessage(role: "user", content: "q"), BackendMessage(role: "assistant", content: "[[reply_to_current]] Done"),
                  BackendMessage(role: "user", content: "next"), BackendMessage(role: "assistant", content: "More")]
    let merged = AppStore.mergeHermesHistory(local: local, server: server)
    #expect(merged?.map(\.content) == ["q", "Done", "next", "More"], "non-destructive: local rows stay, new rows append")
}

@MainActor @Test func theOverviewSaysWhatTheLinkCanDoAndWhy() {
    let (store, bot, gateway, _) = clawStore()
    #expect(store.openClawOverview(bot).facts.map(\.label) == ["Agent", "Session", "Gateway"])
    #expect(store.openClawOverview(bot).facts[2].value == "Test Gateway · Not connected. Press Connect or send a message to connect.")
    var summary = GatewaySummary(protocolVersion: 4, serverVersion: "2026.10.3"); summary.scopes = ["operator.read", "operator.write"]
    summary.methods = ["chat.send", "chat.history", "sessions.create", "agents.list"]
    store.openClawStatus.set(.connected(summary), for: gateway.id)
    let overview = store.openClawOverview(bot)
    #expect(overview.facts.contains(.init(label: "Version", value: "OpenClaw 2026.10.3 · protocol 4")) && overview.facts.contains(.init(label: "Scopes", value: "operator.read, operator.write")))
    #expect(overview.features.first { $0.label == "Stop" }?.reason == "This Gateway does not offer chat.abort.")
    #expect(overview.features.first { $0.label == "Approvals" }?.reason == "This Gateway does not offer exec.approval.resolve.")
    #expect(overview.features.first { $0.label == "Chat" }?.reason == nil && overview.features.first { $0.label == "Reply in thread" }?.reason == nil)
    bot.openClaw = nil
    #expect(store.openClawOverview(bot).facts == [.init(label: "Agent", value: OpenClawBackend.unboundMessage)])
    #expect(OpenClawOverview.routines == "Automations run on the Gateway (cron) and are managed there.")
}

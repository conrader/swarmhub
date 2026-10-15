import Foundation
import Testing
@testable import AgentApp

// P26: an OpenClaw agent as its Gateway's bot manager, over the fake Gateway. Synthetic values only: `agent-alpha`,
// `agent-beta`, `rapper`, `gw-test.example`. No real Gateway, no Keychain.

private let marker = "P26-MANAGER-TEXT-MARKER"

/// Gateway replies in order (the last repeats) and the agents `agents.list` returns; `late` agents appear only from the
/// second `agents.list` on (the Gateway's config hot-reload lagging behind `openclaw agents add`).
private final class GatewayScript: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String], agents: [String], late: [String]; private var sent = 0, lists = 0
    init(replies: [String] = ["ok"], agents: [String] = ["agent-alpha", "agent-beta"], late: [String] = []) { self.replies = replies; self.agents = agents; self.late = late }
    func nextReply() -> String { lock.withLock { sent += 1; return replies[min(sent, replies.count) - 1] } }
    var listCount: Int { lock.withLock { lists } }
    var listed: GatewayJSON {
        let ids = lock.withLock { lists += 1; return lists > 1 ? agents + late : agents }
        return ["defaultId": "agent-alpha", "mainKey": "main", "agents": .array(ids.map { ["id": .string($0)] })]
    }
}

/// An OpenClaw manager (Alpha, `agent-alpha`) whose Gateway answers each `chat.send` with the script's next reply.
@MainActor private func clawManager(_ script: GatewayScript = GatewayScript()) -> (AppStore, Bot, OpenClawGateway, FakeGateway) {
    let fake = FakeGateway()
    fake.handlers["sessions.create"] = echoCreate()
    fake.handlers["agents.list"] = { _, _ in .success(script.listed) }
    fake.handlers["chat.send"] = { params, socket in
        let key = params["sessionKey"] ?? .null, run = GatewayJSON.string(UUID().uuidString)
        socket.push(["type": "event", "event": "chat", "payload": ["runId": run, "sessionKey": key, "seq": 1, "state": "final", "message": assistant(script.nextReply())]])
        return .success(["runId": run, "status": "started"])
    }
    let (store, alpha, gateway, _) = clawStore(fake)
    store.managerTemplateOverride = "\(marker) you are {{MANAGER}}"
    store.botProbeAttempts = 3; store.botProbeDelay = .milliseconds(5)
    store.setCanManageBots(alpha, true)
    return (store, alpha, gateway, fake)
}

@MainActor private func turn(_ store: AppStore, _ text: String) async throws {
    #expect(store.send(text: text))
    try await waitUntil { !store.anyTurnRunning }
}

private func block(_ json: String) -> String { "Done.\n```swarmhub\n\(json)\n```" }

/// A bot bound to `agent` on `gatewayID`.
@MainActor private func clawBot(_ name: String, agent: String, gatewayID: String) -> Bot {
    let bot = Bot(name: name, persona: "", backend: .openClaw); bot.openClaw = .init(gatewayID: gatewayID, agentID: agent); return bot
}

// MARK: 1. Role

@MainActor @Test func oneManagerPerGatewayAndHermesManagersCoexist() {
    let (store, alpha, gateway, _) = clawManager()
    let beta = clawBot("Beta", agent: "agent-beta", gatewayID: gateway.id)
    let other = clawBot("Other", agent: "agent-beta", gatewayID: "gw-other")
    let unbound = Bot(name: "Unbound", persona: "", backend: .openClaw)
    let jarvis = Bot(name: "Jarvis", persona: "", backend: .hermes, hermesProfile: "grok-jarvis")
    store.bots += [beta, other, unbound, jarvis]
    #expect(store.isManager(alpha) && store.connection(of: alpha) == "openclaw:\(gateway.id)")
    store.setCanManageBots(beta, true)
    #expect(beta.canManageBots && !alpha.canManageBots, "a second agent of the same Gateway takes the role over")
    #expect(store.manager(for: alpha)?.id == beta.id)
    store.setCanManageBots(jarvis, true); store.setCanManageBots(other, true)
    #expect(beta.canManageBots && jarvis.canManageBots && other.canManageBots, "Hermes and other Gateways keep their own manager")
    #expect(store.manager(for: jarvis)?.id == jarvis.id && store.manager(for: other)?.id == other.id)
    store.setCanManageBots(unbound, true)
    #expect(!unbound.canManageBots && !store.isManager(unbound), "an unbound OpenClaw bot can't hold the role")
}

@MainActor @Test func theEditorTogglesTheRoleForOpenClawBots() {
    let (store, alpha, _, _) = clawManager()
    var fields = BotEditorFields(bot: alpha)
    #expect(fields.canManage)
    fields.canManage = false; fields.apply(to: alpha, store: store, avatarTouched: false)
    #expect(!alpha.canManageBots)
    fields.canManage = true; fields.apply(to: alpha, store: store, avatarTouched: false)
    #expect(alpha.canManageBots && store.isManager(alpha))
}

// MARK: 2. On demand

@MainActor @Test func theManagerTextRidesInOneMarkedBlockOnlyOnManagementTurns() async throws {
    let script = GatewayScript(replies: ["hello", "Shall I?", block(#"{"op":"instructions_changed","name":"agent-beta"}"#), "ok"])
    let (store, alpha, _, fake) = clawManager(script)
    let typed = ["Good morning", "Create a bot called rapper that raps", "yes", "yes"]
    for text in typed { try await turn(store, text) }
    let messages = fake.requestsFor("chat.send").compactMap { $0["message"]?.string }
    #expect(messages.count == 4)
    #expect(messages[0] == "Good morning", "an ordinary turn sends Konrad's text only")
    for attached in messages[1...2] {
        #expect(attached.hasPrefix(ManagerEnvelope.open) && attached.components(separatedBy: ManagerEnvelope.open).count == 2)
        #expect(attached.contains("\(marker) you are agent-alpha") && !attached.contains("{{"))
    }
    #expect(messages[1].hasSuffix("</swarmhub-manager>\n\nCreate a bot called rapper that raps"))
    #expect(messages[2].hasSuffix("\n\nyes"), "a follow-up within the exchange attaches")
    #expect(messages[3] == "yes", "a swarmhub block closed the exchange")
    #expect(alpha.messages.filter { $0.role == .user }.map(\.content) == typed, "the bubbles show his text only")
}

@Test func hermesBodiesAreByteIdenticalWithTheManagementField() async throws {
    for legacy in [false, true] {
        let (host, backend) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { request, _ in
            if request.url!.path.hasSuffix("/chat/stream") { return .sse([("assistant.delta", ["delta": "ok"]), ("run.completed", [:])]) }
            return ChatParityServer.Reply(body: Data("data: [DONE]\n\n".utf8))
        }
        let history: [(role: String, content: String)] = [(role: "user", content: "earlier"), (role: "assistant", content: "a"), (role: "user", content: "list bots")]
        for try await _ in try await backend.send(.init(sessionID: "s1", systemPrompt: "You are Jarvis.\n\nMANAGER TEXT", messages: history)) {}
        for try await _ in try await backend.send(.init(sessionID: "s1", systemPrompt: "You are Jarvis.", messages: history, managementText: "MANAGER TEXT")) {}
        let bodies = try ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") || $0.path == "/v1/chat/completions" }
            .map { try JSONSerialization.data(withJSONObject: try #require($0.body), options: .sortedKeys) }
        #expect(bodies.count == 2 && bodies[0] == bodies[1], "legacy: \(legacy)")
    }
    let plain = AgentRequest(sessionID: "s", systemPrompt: "P", messages: [])
    #expect(plain.effectiveSystemPrompt == "P")
}

// MARK: 3. Display

@Test func gatewayHistoryNeverShowsTheMarkedBlock() {
    let wrapped = ManagerEnvelope.wrap("SECRET RULES\n```swarmhub\n{}\n```", around: "Create a bot called rapper")
    let page: GatewayJSON = ["messages": [
        ["role": "user", "content": .string(wrapped)],
        ["role": "user", "content": [["type": "text", "text": .string("  \n" + ManagerEnvelope.wrap("RULES", around: "yes"))]]],
        ["role": "assistant", "content": "Shall I?"],
        ["role": "user", "content": .string("quoting <swarmhub-manager v=\"1\">x</swarmhub-manager> mid-text stays")],
    ]]
    let rows = OpenClawHistory.rows(page)
    #expect(rows.map(\.content) == ["Create a bot called rapper", "yes", "Shall I?", "quoting <swarmhub-manager v=\"1\">x</swarmhub-manager> mid-text stays"])
    #expect(ManagerEnvelope.strip("plain") == "plain" && ManagerEnvelope.strip("\(ManagerEnvelope.open) unclosed") == "\(ManagerEnvelope.open) unclosed")
}

// MARK: 4. Template

@Test func theOpenClawTemplateIsFilledSmallAndSafe() throws {
    let url = openClawRepoRoot.appending(path: "Resources/\(BotManagerText.resourcePath(for: .openClaw))")
    let template = try #require(BotManagerText.template(candidates: [url]))
    let hermes = try #require(BotManagerText.template(candidates: [openClawRepoRoot.appending(path: "Resources/\(BotManagerText.resourcePath(for: .hermes))")]))
    let filled = BotManagerText.filled(template, managerAgent: "boss-agent")
    #expect(!filled.contains("{{") && filled.contains("`boss-agent`"))
    #expect(filled.utf8.count <= 3_072)
    for recipe in ["openclaw agents list --json", "openclaw agents add", "--non-interactive --json", "AGENTS.md.prev-$(date -u +%Y%m%d-%H%M%S)",
                   "openclaw agents delete <id> --force --json", "```swarmhub", "\"op\": \"bot_created\"", "exec"] {
        #expect(filled.contains(recipe), "missing \(recipe)")
    }
    for banned in ["cat .env", "cat ~/.openclaw/openclaw.json", "openclaw config set", "API_SERVER_KEY", "nano ", "vim ", "rm -rf"] {
        #expect(!filled.contains(banned), "must not contain \(banned)")
    }
    #expect(filled.contains("Never edit openclaw.json by hand"))
    func avatars(_ text: String) -> String? { text.components(separatedBy: "\n").first { $0.hasPrefix("Avatars are") } }
    #expect(avatars(template) != nil && avatars(template) == avatars(hermes), "same shapes and colours as the Hermes text")
}

// MARK: 5. Blocks

@MainActor @Test func botCreatedBindsTheAgentOnceTheGatewayListsIt() async throws {
    let script = GatewayScript(replies: [block(#"{"op":"bot_created","name":"rapper","description":"Raps.","avatar":{"shape":"star","colour":"red"}}"#)], late: ["rapper"])
    let (store, alpha, gateway, _) = clawManager(script)
    try await turn(store, "Create a bot called rapper")
    try await waitUntil { store.bots.contains { $0.openClaw?.agentID == "rapper" } }
    let rapper = try #require(store.bots.first { $0.openClaw?.agentID == "rapper" })
    #expect(rapper.backend == .openClaw && rapper.openClaw?.gatewayID == gateway.id && rapper.botDescription == "Raps.")
    #expect(rapper.avatarMark?.shape == "star" && rapper.avatarMark?.colour == "red")
    try await waitUntil { alpha.messages.contains { $0.role == .system && $0.content == "Alpha created rapper" } }
    #expect(store.bots.count == 2 && store.managementExchanges[alpha.id] == nil && script.listCount == 2, "bound on the refresh that lists it")
}

@MainActor @Test func botCreatedThatNeverShowsUpSaysSo() async throws {
    let (store, alpha, _, _) = clawManager()
    await store.apply(.botCreated(name: "ghost", description: "", avatar: nil), manager: alpha)
    #expect(alpha.messages.last?.content == "Couldn’t see ghost yet" && store.bots.count == 1)
}

@MainActor @Test func listedAgentsBecomeOffersAndAddBindsThem() async throws {
    let (store, alpha, gateway, _) = clawManager()
    await store.apply(.bots([.init(name: "agent-alpha", description: "me"), .init(name: "agent-beta", description: "Second."), .init(name: "gone", description: "")]), manager: alpha)
    #expect(store.botOffers[alpha.id]?.map(\.name) == ["agent-beta", "gone"], "the manager itself is already a bot")
    await store.addOffered(try #require(store.botOffers[alpha.id]?.first), manager: alpha)
    let beta = try #require(store.boundOpenClawBot("agent-beta", manager: alpha))
    #expect(beta.openClaw == .init(gatewayID: gateway.id, agentID: "agent-beta") && beta.botDescription == "Second.")
    await store.addOffered(try #require(store.botOffers[alpha.id]?.first), manager: alpha)
    #expect(store.botOffers[alpha.id]?.map(\.name) == ["gone"] && store.botOffers[alpha.id]?.first?.state == .unreachable)
}

@MainActor @Test func opsChangeOpenClawBotsOfThatGatewayOnly() async throws {
    let (store, alpha, gateway, _) = clawManager()
    let beta = clawBot("Beta", agent: "agent-beta", gatewayID: gateway.id)
    let elsewhere = clawBot("Elsewhere", agent: "agent-beta", gatewayID: "gw-other")
    let hermesBeta = Bot(name: "Hermes Beta", persona: "", backend: .hermes, hermesProfile: "agent-beta")
    let jarvis = Bot(name: "Jarvis", persona: "", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    store.bots += [beta, elsewhere, hermesBeta, jarvis]
    let untouched = [elsewhere, hermesBeta].map { ($0.avatarMark, $0.botDescription) }
    await store.apply(.avatar(name: "agent-beta", mark: AvatarMark(shape: "heart", colour: "blue")), manager: alpha)
    await store.apply(.description(name: "AGENT-BETA", description: "New."), manager: alpha)
    await store.apply(.instructions(name: "agent-beta", text: "Be brief."), manager: alpha)
    #expect(beta.avatarMark?.shape == "heart" && beta.botDescription == "New." && beta.boxInstructions?.text == "Be brief.")
    await store.apply(.instructionsChanged(name: "agent-beta"), manager: alpha)
    #expect(beta.boxInstructions?.stale == true)
    await store.apply(.botRetired(name: "agent-alpha"), manager: alpha)
    #expect(!alpha.retiredOnBox && !alpha.isHidden, "never the manager itself")
    await store.apply(.botRetired(name: "agent-beta"), manager: alpha)
    #expect(beta.retiredOnBox && beta.isHidden)
    #expect([elsewhere, hermesBeta].map { ($0.avatarMark, $0.botDescription) }.elementsEqual(untouched) { $0 == $1 })
    #expect(![elsewhere, hermesBeta].contains { $0.retiredOnBox || $0.boxInstructions != nil })
    // And the other way round: the Hermes manager's ops never reach OpenClaw bots.
    await store.apply(.description(name: "agent-beta", description: "Hermes side."), manager: jarvis)
    #expect(hermesBeta.botDescription == "Hermes side." && beta.botDescription == "New." && elsewhere.botDescription.isEmpty)
}

import Foundation
import Testing
@testable import AgentApp

// A server's main bot has the app change which agent program and model bots run on; the person can undo it.

private typealias Model = HerdrClient.Template.Model

private func block(_ json: String) -> String { "```swarmhub\n\(json)\n```" }

private let codexModels = [Model(id: "gpt-6.2-sol", label: "GPT-6.2 Sol"), Model(id: "gpt-6.2-sol-mini", label: "GPT-6.2 Sol Mini"), Model(id: "gpt-6.2-terra", label: nil)]
private let claudeModels = [Model(id: "claude-sonnet-5-5", label: nil), Model(id: "claude-opus-5-5", label: "Opus 5.5")]

private func templateJSON(_ name: String, program: String, models: [Model]) -> [String: Any] {
    ["name": name, "description": program, "error": NSNull(), "runtime": ["harness": program, "provider": NSNull(), "model": NSNull()],
     "models": models.map { ["id": $0.id, "label": $0.label.map { $0 as Any } ?? NSNull()] as [String: Any] }, "model_agent": program]
}

private func templates(openCode: Bool = false) throws -> [HerdrClient.Template] {
    let json = [templateJSON("tpl-claude", program: "Claude Code", models: claudeModels), templateJSON("tpl-codex", program: "Codex", models: codexModels)]
        + (openCode ? [templateJSON("tpl-open", program: "OpenCode", models: [])] : [])
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([HerdrClient.Template].self, from: JSONSerialization.data(withJSONObject: json))
}

private func target(_ name: String, on template: String = "tpl-claude", own: String = "", model: String = "") -> HerdrModelPlan.Target {
    HerdrModelPlan.Target(id: UUID(), name: name, ownTemplate: own, template: template, model: model)
}

@Test func aModelRequestIsReadFromAReply() {
    let reply = "Done.\n\n" + block(#"[{"op":"set_model","decision":"decided","bots":"all","runtime":"Codex","model":"sol 6.2"},{"op":"set_model","bots":[" Legal ","legal","Infra"],"model":"Recommended"},{"op":"set_model","bots":"Jarvis","runtime":"Claude"},{"op":"set_model","bots":"all"},{"op":"set_model","model":"x"},{"op":"create_bot","name":"X"}]"#)
    let found = HerdrModelRequest.requests(in: reply)
    #expect(found == [HerdrModelRequest(all: true, runtime: "Codex", model: "sol 6.2", decided: true),
                      HerdrModelRequest(bots: ["Legal", "Infra"], model: nil),
                      HerdrModelRequest(bots: ["Jarvis"], runtime: "Claude")], "a request names bots and a program, a model or both")
    #expect(found[0].who == "All bots" && found[0].what == "Codex · sol 6.2" && found[1].what == "Recommended model")
    #expect(HerdrModelRequest.requests(in: "```swarmhub\n{\"op\":\"set_model\",\"bots\":\"all\",\"model\":\"x\"") .isEmpty, "a fence still being written yields nothing")
    #expect(SwarmhubSummary.lines(in: reply).first?.summary.hasPrefix("Asked to switch all bots to Codex · sol 6.2") == true)
}

@Test func aModelIsFoundByWhatThePersonCalledIt() {
    #expect(HerdrModelRequest.match("sol 6.2", in: codexModels) == .one(codexModels[0]), "the plainest ID that holds every word")
    #expect(HerdrModelRequest.match("GPT-6.2-SOL-MINI", in: codexModels) == .one(codexModels[1]) && HerdrModelRequest.match("gpt-6.2 sol mini", in: codexModels) == .one(codexModels[1]))
    #expect(HerdrModelRequest.match("terra", in: codexModels) == .one(codexModels[2]) && HerdrModelRequest.match("opus 5.5", in: claudeModels) == .one(claudeModels[1]))
    #expect(HerdrModelRequest.match("sonnet 5.5", in: claudeModels) == .one(claudeModels[0]), "two neighbouring numbers of an ID read as one version")
    #expect(HerdrModelRequest.match("6.2", in: [codexModels[0], codexModels[2]]) == .several([codexModels[0], codexModels[2]]), "two equally plain IDs are not guessed between")
    #expect(HerdrModelRequest.match("sol 7", in: codexModels) == .none && HerdrModelRequest.match(" ", in: codexModels) == .none)
}

@Test func aRequestBecomesAPlanOrSaysWhyNot() throws {
    let all = try templates(), offered = ["tpl-claude": claudeModels, "tpl-codex": codexModels]
    let jarvis = target("Jarvis"), legal = target("Legal", on: "tpl-codex", own: "tpl-codex", model: "gpt-6.2-sol"), infra = target("Infra", own: "tpl-claude", model: "claude-opus-5-5")
    func plan(_ request: HerdrModelRequest) -> Result<HerdrModelPlan, HerdrModelRefusal> { HerdrModelPlan.make(request, bots: [jarvis, legal, infra], templates: all, offered: offered) }

    // A model only one program offers moves every bot to that program; a bot already there is left alone.
    let sol = try plan(HerdrModelRequest(all: true, model: "sol 6.2")).get()
    #expect(sol.label == "Codex · GPT-6.2 Sol" && sol.unchanged == 1 && sol.changes.map(\.name) == ["Jarvis", "Infra"])
    #expect(sol.changes.allSatisfy { $0.template == "tpl-codex" && $0.model == "gpt-6.2-sol" } && sol.changes[0].beforeTemplate == "" && sol.changes[1].beforeTemplate == "tpl-claude" && sol.changes[1].beforeModel == "claude-opus-5-5")
    // A named program, with and without a model.
    let claude = try plan(HerdrModelRequest(bots: ["legal"], runtime: "claude")).get()
    #expect(claude.label == "Claude · Recommended model" && claude.changes.count == 1 && claude.changes[0].template == "tpl-claude" && claude.changes[0].model == HerdrModelChoice.recommended)
    // Recommended alone keeps each bot's program.
    let recommended = try plan(HerdrModelRequest(all: true, model: nil)).get()
    #expect(recommended.changes.map(\.template) == ["tpl-claude", "tpl-codex", "tpl-claude"] && recommended.label == "Recommended model")

    #expect(plan(HerdrModelRequest(bots: ["Ghost", "Legal"], model: "sol 6.2")) == .failure(.unknownBots(["Ghost"], known: ["Jarvis", "Legal", "Infra"])))
    #expect(plan(HerdrModelRequest(all: true, runtime: "Llama", model: "x")) == .failure(.noProgram("Llama", offered: ["Claude", "Codex"])))
    #expect(plan(HerdrModelRequest(all: true, runtime: "Codex", model: "sol 7")) == .failure(.noModel("sol 7", program: "Codex", offered: codexModels.map(\.id))))
    #expect(plan(HerdrModelRequest(all: true, model: "sol 7")) == .failure(.noModel("sol 7", program: nil, offered: (claudeModels + codexModels).map(\.id))))
    #expect(plan(HerdrModelRequest(all: true, model: "5.5")) == .failure(.severalModels("5.5", candidates: claudeModels.map(\.id))))
    #expect(HerdrModelPlan.make(HerdrModelRequest(all: true, model: "x"), bots: [], templates: all, offered: offered) == .failure(.noBots))
    // A model several programs offer keeps each bot's program, which must then be one of them.
    let shared = ["tpl-claude": claudeModels + [Model(id: "shared-1", label: nil)], "tpl-codex": codexModels + [Model(id: "shared-1", label: nil)]]
    let kept = try HerdrModelPlan.make(HerdrModelRequest(all: true, model: "shared-1"), bots: [jarvis, legal], templates: all, offered: shared).get()
    #expect(kept.changes.map(\.template) == ["tpl-claude", "tpl-codex"] && kept.label == "shared-1")
    #expect(HerdrModelPlan.make(HerdrModelRequest(all: true, model: "shared-1"), bots: [jarvis, target("Lost", on: "tpl-gone")], templates: all, offered: shared) == .failure(.whichProgram("shared-1", programs: ["Claude", "Codex"])))
    #expect(HerdrModelRefusal.noModel("sol 7", program: "Codex", offered: ["gpt-6.2-sol"]).text == "Codex has no model matching “sol 7”. Models: gpt-6.2-sol.")
    // An ID the server does not list is taken as written only for a program the request names: alone it moves nobody.
    let wider = try templates(openCode: true)
    #expect(HerdrModelPlan.make(HerdrModelRequest(all: true, model: "acme/fast-1"), bots: [jarvis], templates: wider, offered: offered) == .failure(.noModel("acme/fast-1", program: nil, offered: (claudeModels + codexModels).map(\.id))))
    let typed = try HerdrModelPlan.make(HerdrModelRequest(all: true, runtime: "OpenCode", model: "acme/fast-1"), bots: [jarvis], templates: wider, offered: offered).get()
    #expect(typed.changes.map(\.template) == ["tpl-open"] && typed.changes.map(\.model) == ["acme/fast-1"] && typed.label == "OpenCode · acme/fast-1")
}

@Test func aMessageThatAsksForAnotherModelIsRecognised() {
    for text in ["Ustaw boty na sol 6.2 - wszystkie", "set all bots to Sonnet", "Switch Legal to gpt-6.2-sol please", "zmień model Infry", "Przełącz wszystkie na Codex"] {
        #expect(ManagementIntent.changesModel(text), "\(text)")
    }
    for text in ["What is the weather?", "Tell me about the sonnet form", "Set a reminder", "Run the codex review", "Use the Gemini API here",
                 "Change the User model to add an email field"] { #expect(!ManagementIntent.changesModel(text), "\(text)") }
    #expect(HerdrModelRequest.brief.contains(HerdrModelRequest.marker) && HerdrModelRequest.brief.utf8.count < 520, "the standing note is short: the notes share a small room")
    #expect(HerdrModelRequest.elsewhere(main: "Jarvis").contains("The main bot, Jarvis, can have SwarmHub do it") && HerdrModelRequest.elsewhere(main: nil).contains("ignore this note"))
}

// MARK: In the app

/// A Herdr agent that answers from a script: what it is sent decides what it replies.
private struct ScriptedBackend: AgentBackend {
    let kind = BackendKind.herdr
    let reply: @Sendable (String) -> String
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let text = request.messages.last { $0.role == "user" }?.content ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(.replace(reply(text))); continuation.yield(.completed); continuation.finish()
        }
    }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func testConnection() async throws -> String { "Scripted" }
}

/// The server as the app reads it: two programs with their models, the agents that run, and which were ended.
private final class ModelBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [[String: Any]] = [], endedNames: [String] = []
    var ended: [String] { lock.withLock { endedNames } }

    func run(_ name: String) {
        lock.withLock { agents.append(["address": "a\(agents.count)", "created_ms": 10 + agents.count, "name": name, "state": "live", "template": "tpl-claude", "status": NSNull(), "first_message": NSNull()]) }
    }

    func session() -> (address: String, session: URLSession) {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        return ("http://\(host)", session)
    }

    private func answer(_ request: URLRequest) -> (Int, Any) {
        let path = request.url?.path ?? ""
        return lock.withLock { () -> (Int, Any) in
            if request.httpMethod == "GET", path == "/api/workspace" {
                return (200, ["core": "c", "version": "1", "agents": agents,
                              "templates": [templateJSON("tpl-claude", program: "Claude Code", models: claudeModels), templateJSON("tpl-codex", program: "Codex", models: codexModels)]])
            }
            if request.httpMethod == "POST", path.hasSuffix("/end") {
                let address = String(path.split(separator: "/")[2])
                endedNames += agents.filter { $0["address"] as? String == address }.compactMap { $0["name"] as? String }
                agents.removeAll { $0["address"] as? String == address }
                return (200, [String: Any]())
            }
            return (404, ["error": "no route"])
        }
    }
}

/// Jarvis, the main bot, answers a request for a model with a block: decided for "sol", left to the person for
/// "opus", a model nobody has for "nova" (and the right one once it is told so). Legal and Infra only talk.
@MainActor private func modelStore() -> (store: AppStore, jarvis: Bot, legal: Bot, infra: Bot, bridge: ModelBridge) {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { bot in
        guard bot.name == "Jarvis" else { return ScriptedBackend { _ in "Fine." } }
        return ScriptedBackend { text in
            if text.contains("not applied") { return "Corrected.\n\n" + block(#"{"op":"set_model","decision":"decided","bots":"all","runtime":"Codex","model":"gpt-6.2-terra"}"#) }
            if text.contains("nova") { return "On it.\n\n" + block(#"{"op":"set_model","decision":"decided","bots":"all","runtime":"Codex","model":"nova 9"}"#) }
            if text.contains("opus") { return "Shall I?\n\n" + block(#"{"op":"set_model","decision":"ask","bots":["Legal"],"model":"opus 5.5"}"#) }
            if text.contains("sol") { return "Done: the setting is changed.\n\n" + block(#"{"op":"set_model","decision":"decided","bots":"all","model":"sol 6.2"}"#) }
            return "Hello."
        }
    }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bridge = ModelBridge(), served = bridge.session()
    store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
    store.herdrClientSetup = { made in made.session = served.session }
    let jarvis = Bot(name: "Jarvis", backend: .herdr), legal = Bot(name: "Legal", backend: .herdr), infra = Bot(name: "Infra", backend: .herdr)
    store.bots = [jarvis, legal, infra]
    store.setCanManageBots(jarvis, true)
    store.setHerdrTemplate("tpl-claude", for: infra); store.setHerdrModel("claude-opus-5-5", for: infra)
    return (store, jarvis, legal, infra, bridge)
}

@MainActor private func lines(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }
@MainActor private func choice(_ store: AppStore, _ bot: Bot) -> String { "\(store.herdrTemplate(for: bot) ?? "-")|\(store.herdrModel(for: bot))" }

@MainActor @Test func theMainBotSwitchesEveryBotAndThePersonCanUndoIt() async throws {
    let (store, jarvis, legal, infra, _) = modelStore()
    #expect(try store.herdrBackend(for: jarvis).notes.contains { $0.marker == HerdrModelRequest.marker } && store.herdrBackend(for: legal).modelBrief == nil)
    #expect(store.send(text: "Ustaw boty na sol 6.2 - wszystkie", bot: jarvis, conversation: jarvis, replyToID: nil))
    try await waitUntil { store.herdrModelRecord(by: jarvis, on: store.herdrServer(for: jarvis)) != nil && store.isIdle(jarvis) }
    #expect([jarvis, legal, infra].map { choice(store, $0) } == Array(repeating: "tpl-codex|gpt-6.2-sol", count: 3))
    #expect(lines(jarvis).contains("Jarvis switched 3 bots to Codex · GPT-6.2 Sol.") && store.pendingHerdrModels(for: jarvis).isEmpty)
    #expect([jarvis, legal, infra].allSatisfy { store.herdrCarryOver(for: $0) != nil }, "each changed bot is noted: its next agent reads the bot's chat first")
    let record = try #require(store.herdrModelRecord(by: jarvis, on: store.herdrServer(for: jarvis)))
    #expect(record.changes.count == 3 && record.notFresh == 3)
    // A bot the person has moved on since keeps that choice; the others go back to exactly what they had.
    store.setHerdrModel("gpt-6.2-terra", for: legal)
    #expect(store.undoHerdrModels(record) == 2)
    #expect(choice(store, jarvis) == "-|" && choice(store, infra) == "tpl-claude|claude-opus-5-5" && choice(store, legal) == "tpl-codex|gpt-6.2-terra")
    #expect(store.herdrModelRecord(by: jarvis, on: store.herdrServer(for: jarvis)) == nil && lines(jarvis).contains("You undid the switch to Codex · GPT-6.2 Sol: 2 bots went back to what they ran before."))
}

@MainActor @Test func aChangeLeftToThePersonWaitsForApply() async throws {
    let (store, jarvis, legal, _, _) = modelStore()
    #expect(store.send(text: "Could Legal use opus?", bot: jarvis, conversation: jarvis, replyToID: nil))
    try await waitUntil { store.pendingHerdrModels(for: jarvis).count == 1 }
    let pending = try #require(store.pendingHerdrModels(for: jarvis).first)
    #expect(pending.request.who == "Legal" && choice(store, legal) == "-|" && store.herdrModelRecords.isEmpty, "nothing changes before Apply")
    #expect(await store.acceptHerdrModel(pending, manager: jarvis) == nil)
    #expect(choice(store, legal) == "tpl-claude|claude-opus-5-5" && store.pendingHerdrModels(for: jarvis).isEmpty && lines(jarvis).contains("Jarvis switched 1 bot to Claude · Opus 5.5."))
    // With "Ask me before creating bots" on, a decided change waits too.
    let asking = modelStore()
    asking.store.setHerdrAsksFirst(true, for: asking.jarvis)
    #expect(asking.store.send(text: "all on sol", bot: asking.jarvis, conversation: asking.jarvis, replyToID: nil))
    try await waitUntil { asking.store.pendingHerdrModels(for: asking.jarvis).count == 1 }
    #expect(asking.store.herdrModelRecords.isEmpty && choice(asking.store, asking.legal) == "-|")
    asking.store.dismissHerdrModel(try #require(asking.store.pendingHerdrModels(for: asking.jarvis).first))
    #expect(asking.store.pendingHerdrModels(for: asking.jarvis).isEmpty)
}

@MainActor @Test func aModelNobodyHasGoesBackToTheMainBotOnce() async throws {
    let (store, jarvis, legal, _, _) = modelStore()
    #expect(store.send(text: "put everyone on nova", bot: jarvis, conversation: jarvis, replyToID: nil))
    try await waitUntil { store.herdrModelRecord(by: jarvis, on: store.herdrServer(for: jarvis)) != nil && store.isIdle(jarvis) }
    let told = try #require(jarvis.messages.first { $0.metadata[HerdrModelRequest.outcomeKey] != nil })
    #expect(told.role == .user && told.content.hasPrefix("[From SwarmHub]\nThe model change was not applied. Codex has no model matching “nova 9”. Models: gpt-6.2-sol, gpt-6.2-sol-mini, gpt-6.2-terra."))
    #expect(store.isAppWritten(told) && choice(store, legal) == "tpl-codex|gpt-6.2-terra", "its corrected request is applied without another question")
    #expect(jarvis.messages.filter { $0.metadata[HerdrModelRequest.outcomeKey] != nil }.count == 1)
}

@MainActor @Test func freshAgentsAreStartedOnceAndSettingsDoesTheSame() async throws {
    let (store, jarvis, legal, infra, bridge) = modelStore()
    let server = store.herdrServer(for: jarvis)
    let all = try await store.herdrTemplates(on: server), codex = try #require(all.first { $0.name == "tpl-codex" })
    let record = try #require(store.setHerdrModelForAll(on: server, template: codex, model: "gpt-6.2-sol", label: "Codex · GPT-6.2 Sol", templates: all))
    #expect(record.manager == nil && record.changes.count == 3 && store.herdrModelRecord(by: nil, on: server)?.id == record.id && store.herdrModelRecord(by: jarvis, on: server) == nil)
    #expect(store.setHerdrModelForAll(on: server, template: codex, model: "gpt-6.2-sol", label: "Codex · GPT-6.2 Sol", templates: all) == nil, "nothing to change the second time")
    for bot in [legal, infra] { bridge.run(HerdrBackend.agentName(botName: bot.name, botID: bot.id)) }
    let note = await store.startFreshHerdrAgents(record)
    #expect(note == "3 bots start fresh with their next message." && bridge.ended.count == 2, "a bot with no agent running starts fresh anyway")
    let after = try #require(store.herdrModelRecord(by: nil, on: server))
    #expect(after.notFresh == 0 && after.note == note)
    bridge.run(HerdrBackend.agentName(botName: legal.name, botID: legal.id))
    await store.startFreshHerdrAgents(after)
    #expect(bridge.ended.count == 2, "an agent that already started fresh is not ended again")
    store.doneWithHerdrModels(after)
    #expect(store.herdrModelRecord(by: nil, on: server) == nil)
}

@MainActor @Test func twoChangesStandSideBySideAndUndoAfterAFreshStartKeepsThoseBotsOnACard() async throws {
    let (store, jarvis, legal, _, _) = modelStore()
    let server = store.herdrServer(for: jarvis)
    let all = try await store.herdrTemplates(on: server), codex = try #require(all.first { $0.name == "tpl-codex" })
    let first = try #require(store.setHerdrModelForAll(on: server, template: codex, model: "gpt-6.2-sol", label: "Codex · GPT-6.2 Sol", templates: all))
    let again = HerdrModelPlan(changes: [.init(bot: legal.id, name: "Legal", template: "tpl-claude", model: "claude-opus-5-5", beforeTemplate: "tpl-codex", beforeModel: "gpt-6.2-sol")], unchanged: 0, label: "Claude · Opus 5.5")
    let second = try #require(store.applyHerdrModels(again, on: server, by: nil))
    #expect(store.herdrModelRecords(by: nil, on: server).map(\.id) == [first.id, second.id], "a change just made stays beside the next one")
    await store.startFreshHerdrAgents(first)
    let started = try #require(store.herdrModelRecords(by: nil, on: server).first)
    #expect(started.notFresh == 0 && store.undoHerdrModels(started, running: [:]) == 2, "Legal was changed again since and keeps that")
    let left = store.herdrModelRecords(by: nil, on: server)
    #expect(left.map(\.undo) == [false, true] && left.last?.changes.map(\.name) == ["Jarvis", "Infra"] && left.last?.changes.first?.template == "")
    let back = try #require(left.last)
    #expect(HerdrModelRecordRow.title(back, by: nil) == "2 bots are back on what they ran before" && store.undoHerdrModels(back) == 0, "going back has no Undo of its own")
    #expect(HerdrModelRecordRow.title(second, by: "Jarvis") == "Jarvis switched 1 bot to Claude · Opus 5.5")
}

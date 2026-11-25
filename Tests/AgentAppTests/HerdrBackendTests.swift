import Foundation
import Testing
@testable import AgentApp

@Test func herdrAddressesAreLocalRootsOnly() {
    #expect(HerdrClient.validatedBaseURL("http://127.0.0.1:8787/")?.absoluteString == "http://127.0.0.1:8787")
    #expect(HerdrClient.validatedBaseURL(" https://localhost:9000 ")?.absoluteString == "https://localhost:9000")
    for bad in ["127.0.0.1:8787", "http://host/path", "ftp://host", "http://host?x=1", ""] { #expect(HerdrClient.validatedBaseURL(bad) == nil, "\(bad)") }
}

/// The bridge accepts 1–32 of `a-z 0-9 . - _`; the id suffix keeps a renamed bot on the same agent.
@Test func herdrAgentNamesFitTheBridge() {
    #expect(HerdrClient.agentName(for: "Ada Lovelace!", suffix: "1A2B3C4D5E") == "ada-lovelace-1a2b3c")
    #expect(HerdrClient.agentName(for: "Zażółć", suffix: "ABCDEF12") == "za-abcdef")
    #expect(HerdrClient.agentName(for: "!!!", suffix: "abcdef12") == "agent-abcdef")
    let long = HerdrClient.agentName(for: String(repeating: "word ", count: 20), suffix: "abcdef12")
    #expect(long.count <= 32 && long.hasSuffix("-abcdef") && !long.contains("--"))
    #expect(HerdrClient.suffix(of: "ada-lovelace-1a2b3c") == HerdrClient.suffix(of: "renamed-1a2b3c"))
}

@Test(arguments: [false, true], ["stopped", "exited", "still_working", "unknown", "legacy"])
func herdrStopFindsTheRightAgentWhileDeliveryIsStillSending(inGroup: Bool, outcome: String) async throws {
    let id = UUID()
    let groupSession = GroupRouting.sessionID(group: UUID(), bot: id)
    let sessionID = inGroup ? groupSession : id.uuidString
    let direct = HerdrBackend.agentName(botName: "Ada", botID: id)
    let group = try #require(HerdrBackend.groupRuntimeName(sessionID: groupSession, botID: id))
    let address = inGroup ? "t2" : "t1"
    let target = "/api/agents/\(address)/1"
    let (host, session) = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace":
            let agents = [["name": direct, "address": "t1", "created_ms": 1, "state": "live"],
                          ["name": group, "address": "t2", "created_ms": 1, "state": "live"]] as [[String: Any]]
            return (200, ["core": "c", "agents": agents, "templates": []])
        case "/api/history/c/\(address)/1", "/api/history/c/\(address)/1/draft": return (200, ["items": [], "tools": []])
        case target + "/messages": return (200, MockHTTPProtocol.PendingResponse())
        case target + "/interrupt": return (200, outcome == "legacy" ? [:] : ["outcome": outcome])
        default: return (404, ["error": "Unexpected fixture route"])
        }
    }
    let client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
    let backend = HerdrBackend(client: client, botName: "Ada", botID: id, template: nil)
    let stream = try await backend.send(.init(sessionID: sessionID, systemPrompt: "", messages: [(role: "user", content: "Hello")], images: []))
    let consuming = Task { for try await _ in stream {} }
    defer { consuming.cancel() }
    try await MockHTTPProtocol.log(host).wait(ceiling: .seconds(5)) { $0.contains { $0.url?.path == target + "/messages" } }
    let expected: StopOutcome = switch outcome {
    case "stopped", "exited": .requested
    case "still_working": .stillWorking
    default: .unconfirmed
    }
    #expect(try await backend.cancel(sessionID: sessionID) == expected)
    #expect(MockHTTPProtocol.recorded(host).filter { $0.url?.path.hasSuffix("/interrupt") == true }.map { $0.url?.path } == [target + "/interrupt"])
}

/// Claude Code's and Codex's tool calls show with the chat's own step words; a start is reported once.
@Test func herdrToolCallsBecomeActivitySteps() {
    let running = HerdrClient.ToolCall(seq: 7, tool: "Bash", detail: "cargo test", finished: false, failed: false)
    #expect(HerdrBackend.toolEvents(running, isNew: true) == [ToolEvent(phase: .started, name: "bash", preview: "cargo test", callID: "herdr-7")])
    #expect(HerdrBackend.toolEvents(running, isNew: false).isEmpty)
    let failed = HerdrClient.ToolCall(seq: 7, tool: "Bash", detail: nil, finished: true, failed: true)
    #expect(HerdrBackend.toolEvents(failed, isNew: false) == [ToolEvent(phase: .failed, name: "bash", callID: "herdr-7")])
    #expect(HerdrBackend.toolEvents(failed, isNew: true).map(\.phase) == [.started, .failed])
    #expect(["apply_patch", "Edit", "Read", "WebSearch", "mcp__x__y"].map(HerdrBackend.toolName) == ["edit_file", "edit_file", "read_file", "web_search", "mcp__x__y"])
    #expect(ActivityCopy.label(HerdrBackend.toolName("Bash")) == "Running a command" && ActivityCopy.label(HerdrBackend.toolName("apply_patch")) == "Editing a file")
}

/// Starter bots begin on the first model the server offers; the app names none itself.
@Test @MainActor func herdrStarterModelIsTheServersFirst() {
    let first = HerdrClient.Template.Model(id: "first-model", label: nil), second = HerdrClient.Template.Model(id: "second-model", label: nil)
    #expect(AppStore.starterModel(offered: [first, second]) == "first-model")
    #expect(AppStore.starterModel(offered: []) == nil)
}

/// What a bot runs on is shown by the server's names: "no choice" resolves to the agent program new bots use and to
/// the first model the server offers, and the running agent's model is the one its session was launched with.
@MainActor @Test func aHerdrBotsRuntimeAndModelAreNamedNeverVague() throws {
    let one = HerdrClient.Template(name: "tpl-one", description: nil, error: nil, runtime: .init(harness: "Agent One", provider: nil, model: nil), modelAgent: "one")
    let two = HerdrClient.Template(name: "tpl-two", description: nil, error: nil, runtime: .init(harness: "Agent Two", provider: nil, model: nil))
    let offered = [HerdrClient.Template.Model(id: "m-a", label: "Model A"), HerdrClient.Template.Model(id: "m-b", label: "Model B")]
    let plain = HerdrAgentReading(templates: [one, two], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered)
    #expect(plain.runtimeLine == "Agent One (default)" && plain.modelLine == "Model A (default)" && plain.short == "Model A" && plain.runningLine == nil && plain.pendingLine == nil)
    #expect(plain.summary == "AI: Agent One (default). Model: Model A (default).")
    #expect(plain.model?.id == HerdrClient.defaultModel(offered: offered) && AppStore.starterModel(offered: offered) == "m-a", "the model shown is the one a start sends, by the rule starter bots use")
    let own = HerdrAgentReading(templates: [one, two], ownTemplate: "tpl-one", sharedTemplate: "tpl-two", ownModel: "m-b", offered: offered)
    #expect(own.runtimeLine == "Agent One" && own.modelLine == "Model B", "its own choices carry no (default)")
    let listless = HerdrAgentReading(templates: [one, two], ownTemplate: nil, sharedTemplate: "tpl-two", ownModel: "m-b", offered: [])
    #expect(listless.runtimeLine == "Agent Two (default)" && listless.modelLine == HerdrAgentReading.programPicks && listless.short == nil, "no list: the agent program picks, and no model is named")
    #expect(HerdrAgentReading(templates: [one], ownTemplate: "gone", sharedTemplate: nil, ownModel: nil, offered: []).runtimeLine == "None set up on this server")
    #expect(HerdrAgentReading.defaultLabel(shared: "tpl-two", in: [one, two]) == "Agent Two (default)" && HerdrAgentReading.defaultLabel(shared: nil, in: [one, two]) == "Agent One (default)" && HerdrAgentReading.defaultLabel(shared: nil, in: []) == nil)

    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let agent = try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t9","created_ms":77,"name":"x-abc123","state":"live","template":"tpl-one","status":null}"#.utf8))
    let older = try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t8","created_ms":70,"name":"x-abc123","state":"live","template":"tpl-one","status":null}"#.utf8))
    let profiles = try decoder.decode([HerdrClient.Profile].self, from: Data("""
    [{"id":1,"runtime_name":"x-abc123","sessions":[{"core":"c","address":"t9","created_ms":77,"template":"tpl-one","runtime":{"harness":"Agent One","provider":null,"model":"m-b","model_id":"m-b"}},
                                                  {"core":"c","address":"t8","created_ms":70,"template":"tpl-one","runtime":{"harness":"Agent One","provider":null,"model":null}}]},
     {"id":2,"runtime_name":"an-older-bridge-without-sessions"}]
    """.utf8))
    let running = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: agent, profiles: profiles)
    #expect(running.running == .model(id: "m-b", label: "Model B") && running.short == "Model B" && running.runningLine == "Current session started on Model B.")
    #expect(running.pendingLine == "Model A will answer your next new direct turn.", "another model is chosen than the one running: it says when it applies")
    #expect(plain.headerModel == "Next direct turn · Model A" && plain.pendingTarget == nil)
    #expect(running.headerModel == "Started on Model B" && running.pendingTarget == "Model A")
    var confirmed = running
    confirmed.confirmed = true
    #expect(confirmed.headerModel == "Last confirmed · Model B")
    var changedProgram = running
    changedProgram.activeTemplate = "old-program"
    #expect(changedProgram.changesProgram && changedProgram.pendingLine == "Next new direct turn: Agent One · Model A. Your chat stays here.")
    #expect(changedProgram.pendingTarget == "Agent One · Model A")
    changedProgram.model = nil
    #expect(changedProgram.pendingLine == "Next new direct turn: Agent One. Your chat stays here.")
    let same = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: "m-b", offered: offered, agent: agent, profiles: profiles)
    #expect(same.pendingLine == nil && same.summary == "AI: Agent One (default). Model: Model B. Current session started on Model B.")
    let unstated = HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: older, profiles: profiles)
    #expect(unstated.headerModel == "Agent One · Model unreported")
    var switching = unstated
    switching.runtime = two
    #expect(switching.headerModel == "Agent One · Model unreported")
    #expect(unstated.running == .unstated && unstated.short == nil && unstated.runningLine?.contains("it picked itself") == true && unstated.pendingLine == "Model A will answer your next new direct turn.", "an agent started without a model is not given one by guess")
    #expect(HerdrAgentReading(templates: [one], ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: offered, agent: agent, profiles: []).running == .unknown)
}

@MainActor @Test func docComposerRechecksNativeSteeringAfterDirectPreparationAtAPermissionPrompt() async throws {
    let bot = Bot(name: "Doc", backend: .herdr)
    let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let events = AwaitableLog<String>()
    let (host, session) = MockHTTPProtocol.serve { request in
        let blocked = events.all.contains("started")
        let finished = events.all.contains("finished")
        switch request.url?.path {
        case "/api/workspace":
            let state = finished ? "done" : blocked ? "blocked" : "idle"
            let agent: [String: Any] = ["name": name, "address": "doc", "created_ms": 7, "state": "live",
                "template": "codex", "status": ["state": state, "kind": "permission"], "auto_restart_pending": true,
                "codex_policy": "on-request", "codex_reviewer": "user", "codex_sandbox": "read-only"]
            return (200, ["core":"fixture-core","codex_turn_steer":true,"agents":[agent],
                          "templates":[["name":"codex","runtime":["harness":"Codex"]]]])
        case "/api/history/fixture-core/doc/7":
            var rows: [[String: Any]] = blocked ? [["id":1,"kind":"task","state":"sent","text":"Read the fixture"]] : []
            if finished { rows.append(["id":2,"kind":"reply","text":"Fixture done"]) }
            return (200, ["items": rows])
        case "/api/history/fixture-core/doc/7/draft": return (200, ["tools":[]])
        case "/api/profiles": return (200, [])
        case "/api/agents/doc/7/messages":
            events.append("started")
            return (200, [:])
        case "/api/agents/doc/7/steer":
            guard let data = request.bodyData, let body = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  body["text"] == "Include the manifest", body["expected_core"] == "fixture-core",
                  UUID(uuidString: body["reference"] ?? "") != nil else { return (409, [:]) }
            events.append("steered")
            return (200, ["delivered":true])
        default: return (404, ["error":"Unknown fixture route"])
        }
    }
    var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "fixture", session: session)
    client.following = .polling
    client.pollInterval = .milliseconds(10)
    client.agentCheckInterval = .milliseconds(10)
    var configured = HerdrBackend(client: client, botName: bot.name, botID: bot.id, template: "codex")
    configured.prepareDirect = { _, _ in [] }
    let backend = configured
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.bots = [bot]; store.open(bot, remember: false)
    let active = try #require(try await client.workspace().agents.first)
    #expect(active.autoRestartPending == true && active.reviewDescription?.contains("read-only · on-request") == true)
    #expect(store.send(text: "Inspect the fixture directory"))
    try await waitUntil { store.herdrWaits(bot).waits && store.canSteer(in: bot) }
    #expect(store.send(text: "Include the manifest"))
    let row = try #require(bot.messages.last)
    try await waitUntil { row.metadata[SteerKey.steer] == "delivered" }
    #expect(!store.isIdle(bot) && events.all == ["started", "steered"] && store.herdrWaits(bot).waits)
    events.append("finished")
    try await waitUntil { store.isIdle(bot) }
    #expect(MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }.map { $0.url!.path } ==
            ["/api/agents/doc/7/messages", "/api/agents/doc/7/steer"])
}

@Test(arguments: ["Claude", "Codex", "legacy Codex", "renamed Claude"])
func nextMessageWaitsForCoreAfterThePreviousReplyIsSaved(provider: String) async throws {
    let harness = provider.lowercased().contains("claude") ? "Claude" : "Codex"
    let program = provider == "renamed Claude" ? "Codex" : harness
    let legacy = provider == "legacy Codex"
    let ready = LockedValue(false)
    let (host, session) = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace":
            let agent: [String: Any] = ["address": "p", "name": "bot", "created_ms": 7,
                "state": "live", "template": "tpl", "status": ["state": ready.current ? "idle" : "working"]]
            var roster: [String: Any] = ["core": "c", "templates": [["name": "tpl", "runtime": ["harness": harness, "display_name": program]]],
                "agents": [agent], "bridge": ["api": legacy ? 2 : 3, "version": legacy ? "0.2.12" : "0.2.13"]]
            if !legacy { roster["codex_turn_steer"] = true }
            return (200, roster)
        case "/api/history/c/p/7": return (200, ["items": [["id": 23, "kind": "reply", "text": "Prior answer"]]])
        case "/api/history/c/p/7/draft": return (200, ["tools": []])
        case "/api/agents/p/7/messages": return (200, ["queued": false])
        default: return (404, [:])
        }
    }
    var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "fixture", session: session)
    client.agentCheckInterval = .milliseconds(5)
    let sender = client
    let task = Task { try await sender.deliver("Next question", name: "bot", template: "tpl") }
    defer { task.cancel() }
    try await MockHTTPProtocol.log(host).wait { $0.count >= 2 }
    #expect(MockHTTPProtocol.recorded(host).allSatisfy { $0.url?.path == "/api/workspace" })
    _ = ready.swap(true)
    let turn = try await task.value
    #expect(turn.after == 23 && turn.program == program)
    let posts = MockHTTPProtocol.recorded(host).filter { $0.httpMethod == "POST" }
    #expect(posts.count == 1)
    let data = try #require(posts.first?.bodyData)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(body["text"] == "Next question" && body["expected_core"] == "c")
    #expect(body["turn_reference"] == turn.steerReference)
    #expect((turn.steerReference != nil) == (provider == "Codex"))
}

@Test(arguments: ["replaced", "blocked", "lost status", "timeout"])
func busyDeliveryNeverPostsOnAnUnconfirmedSession(outcome: String) async throws {
    let first = LockedValue(true)
    let (host, session) = MockHTTPProtocol.serve { _ in
        let initial = first.swap(false)
        let agent: [String: Any] = ["address": "p", "name": "bot", "created_ms": !initial && outcome == "replaced" ? 2 : 1,
            "state": "live", "status": ["state": initial ? "working" : outcome == "replaced" ? "idle" : outcome]]
        return (200, ["core": "c", "templates": [], "agents": [agent]])
    }
    var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "fixture", session: session)
    client.agentCheckInterval = .milliseconds(1)
    if outcome == "timeout" { client.busyWaitLimit = .zero }
    do {
        _ = try await client.deliver("Next question", name: "bot", template: nil)
        Issue.record("The workspace did not confirm the original session was ready")
    } catch let failure as HerdrClient.Failure {
        if outcome == "blocked" { #expect(failure == .waitingAtPrompt) }
        else if case .notDelivered = failure {} else { Issue.record("Unexpected failure: \(failure)") }
    }
    #expect(MockHTTPProtocol.recorded(host).allSatisfy { $0.url?.path == "/api/workspace" })
}

@Test func stoppingAWaitForAnotherWorkspaceTaskDoesNotInterruptIt() async throws {
    let id = UUID(), name = HerdrBackend.agentName(botName: "Ada", botID: id)
    let (host, session) = MockHTTPProtocol.serve { _ in
        (200, ["core": "c", "templates": [], "agents": [
            ["name": name, "address": "p", "created_ms": 1, "state": "live", "status": ["state": "working"]]]])
    }
    var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "fixture", session: session)
    client.agentCheckInterval = .milliseconds(5)
    let backend = HerdrBackend(client: client, botName: "Ada", botID: id, template: nil)
    let stream = try await backend.send(.init(sessionID: id.uuidString, systemPrompt: "", messages: [("user", "Wait")]))
    let consumer = Task { for try await _ in stream {} }
    defer { consumer.cancel() }
    try await MockHTTPProtocol.log(host).wait { $0.count >= 2 }
    #expect(try await backend.cancel(sessionID: id.uuidString) == .noActiveRun)
    consumer.cancel()
    _ = await consumer.result
    #expect(MockHTTPProtocol.recorded(host).allSatisfy { $0.httpMethod == "GET" })
}

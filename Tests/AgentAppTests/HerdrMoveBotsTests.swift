import Foundation
import Testing
@testable import AgentApp

@MainActor @Suite struct HerdrMoveBotsTests {
    @MainActor private struct Fixture {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let main = Bot(name: "Main", backend: .herdr)
        let analyst = Bot(name: "Analyst", backend: .herdr)
        let writer = Bot(name: "Writer", backend: .herdr)
        let source: HerdrServer
        let destination: HerdrServer
        let sourceHost: String
        let project = HerdrBotProject(id: 7, name: "Source repo", machine: "This Mac")

        init(remoteWorking: Bool = false, sourceOffline: Bool = false) {
            let mainAgent = HerdrBackend.agentName(botName: main.name, botID: main.id)
            let analystAgent = HerdrBackend.agentName(botName: analyst.name, botID: analyst.id)
            let sourceBridge = MockHTTPProtocol.serve { request in
                if sourceOffline { return (503, ["error": "Workspace offline"]) }
                if request.url?.path == "/api/routines" { return (200, []) }
                if request.url?.path.hasSuffix("/end") == true { return (200, [:]) }
                let ended = MockHTTPProtocol.recorded(request.url?.host ?? "").compactMap(\.url?.path)
                return (200, Self.workspace("this-mac", templates: [
                    Self.template("claude-local", "Claude Code", ["sonnet"]),
                    Self.template("codex-local", "Codex", ["sol", "local-only"])
                ], agents: [
                    Self.agent("main-agent", name: mainAgent, status: "idle"),
                    Self.agent("analyst-agent", name: analystAgent, status: remoteWorking ? "working" : "idle")
                ].filter { agent in
                    guard let address = agent["address"] as? String else { return true }
                    return !ended.contains("/api/agents/\(address)/42/end")
                }))
            }
            let destinationBridge = MockHTTPProtocol.serve { _ in
                (200, Self.workspace("vps-core", templates: [
                    Self.template("default-vps", "OpenCode", ["provider/fast"]),
                    Self.template("codex-vps", "Codex", ["sol", "terra"]),
                    Self.template("broken-claude", "Claude Code", ["sonnet"], error: "Unavailable")
                ]))
            }
            source = HerdrServer(id: HerdrServer.defaultID, name: "This Mac", kind: .local, address: "http://\(sourceBridge.host)")
            destination = HerdrServer(id: "vps", name: "VPS", kind: .address, address: "http://\(destinationBridge.host)")
            sourceHost = sourceBridge.host
            store.bots = [main, analyst, writer]
            store.saveHerdrServers([source, destination])
            store.setHerdrToken("source-key", for: source)
            store.setHerdrToken("destination-key", for: destination)
            store.herdrClientSetup = { $0.session = sourceBridge.session }
            store.setCanManageBots(main, true)
            store.setHerdrTemplate("claude-local", for: main)
            store.setHerdrModel("sonnet", for: main)
            store.setHerdrTemplate("codex-local", for: analyst)
            store.setHerdrModel("sol", for: analyst)
            store.setHerdrTemplate("codex-local", for: writer)
            store.setHerdrModel("local-only", for: writer)
            store.setHerdrProjects([project], for: main)
            store.setHerdrProjects([project], for: writer)
            main.messages = [ChatMessage(role: .user, content: "My timezone is UTC."),
                             ChatMessage(role: .assistant, content: "I’ll remember UTC.")]
        }

        var ended: [String] {
            MockHTTPProtocol.recorded(sourceHost).filter { $0.httpMethod == "POST" }
                .compactMap { $0.url?.path }.filter { $0.hasSuffix("/end") }
        }

        func move(_ bots: [Bot], mapping: HerdrMoveMapping = .matching, history: Bool = true,
                  stop: Bool = true) async throws -> HerdrServerMoveRecord {
            try await store.moveHerdrBots(Set(bots.map(\.id)), from: source, to: destination, mapping: mapping, carryHistory: history, stopIdleAgents: stop)
        }

        nonisolated private static func workspace(_ core: String, templates: [[String: Any]], agents: [[String: Any]] = []) -> [String: Any] {
            ["core": core, "version": "1", "templates": templates, "agents": agents]
        }

        nonisolated private static func template(_ name: String, _ harness: String, _ models: [String], error: String? = nil) -> [String: Any] {
            ["name": name, "runtime": ["harness": harness], "model_agent": harness, "models": models.map { ["id": $0] },
             "error": error.map { $0 as Any } ?? NSNull()]
        }

        nonisolated private static func agent(_ address: String, name: String, status: String) -> [String: Any] {
            ["name": name, "address": address, "created_ms": 42, "state": "live", "status": ["state": status]]
        }
    }

    @Test func protectedBotCannotMoveToAnUnreviewedTemplate() async throws {
        let f = Fixture(remoteWorking: true)
        f.analyst.requiresToolReview = true
        let request = ChatMessage(role: .user, content: "Check the invoice")
        let reply = ChatMessage(role: .assistant, content: "Reading it.", isStreaming: true)
        f.analyst.messages = [request, reply]
        _ = f.store.beginTurn(in: f.analyst, bot: f.analyst, assistant: reply)
        let workspace = try await f.store.herdrMoveWorkspace(on: f.source)
        let live = try #require(workspace.agents.first { $0.address == "analyst-agent" })
        reply.deliveryReceipt = .init(server: f.source.id, turn: .init(core: "this-mac", address: live.address,
            createdMs: live.createdMs, after: 0, launched: false), text: request.content)
        await #expect(throws: HerdrMoveError.toolReviewUnavailable) {
            try await f.store.moveHerdrBots([f.analyst.id], from: f.source, to: f.destination, mapping: .matching,
                                            carryHistory: true, stopIdleAgents: true, resumeActiveWork: true)
        }
        #expect(f.store.herdrServer(for: f.analyst) == f.source)
        #expect(f.ended.isEmpty)
    }

    @Test func unavailableSourceIsIdentifiedBeforeInterruptingOrMoving() async throws {
        let f = Fixture(sourceOffline: true)
        do {
            _ = try await f.move([f.main])
            Issue.record("Move succeeded while its source was unavailable")
        } catch let error as HerdrMoveSourceUnavailable {
            #expect(error.server == f.source)
            #expect(error.localizedDescription.contains(f.source.name))
        }
        #expect(f.store.herdrServer(for: f.main) == f.source)
        #expect(f.main.messages.count == 2)
        #expect(f.ended.isEmpty)
    }

    @Test func sshDestinationCanShareTheSourceServersPort() throws {
        let f = Fixture()
        let first = HerdrServer(id: "ssh-one", name: "One", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "one")
        let second = HerdrServer(id: "ssh-two", name: "Two", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "two")
        f.store.saveHerdrServer(first, token: "one")
        f.store.saveHerdrServer(second, token: "two")
        let one = try f.store.herdrClient(for: first)
        let two = try f.store.herdrClient(for: second)
        #expect(one.baseURL.port != 8787)
        #expect(two.baseURL.port != 8787)
        #expect(one.baseURL.port != two.baseURL.port)
        let request = try one.request("/api/workspace", method: "GET", body: nil)
        #expect(request.value(forHTTPHeaderField: "Host") == "127.0.0.1:8787")
        #expect(request.value(forHTTPHeaderField: "Origin") == "http://127.0.0.1:8787")
    }

    @Test func matchingProgramsKeepsSupportedModelsAndFallsBackToTheDestinationDefault() async throws {
        let f = Fixture(), store = f.store
        let messageIDs = f.main.messages.map(\.id)
        let record = try await f.move([f.main, f.analyst])
        #expect(record.changes.map(\.botID) == [f.main.id, f.analyst.id])
        #expect(store.herdrServer(for: f.main) == f.destination)
        #expect(store.herdrServer(for: f.analyst) == f.destination)
        #expect(store.herdrTemplate(for: f.main) == "default-vps")
        #expect(store.herdrModel(for: f.main) == HerdrModelChoice.recommended)
        #expect(store.herdrTemplate(for: f.analyst) == "codex-vps")
        #expect(store.herdrModel(for: f.analyst) == "sol")
        #expect(store.herdrProjects(for: f.main).isEmpty)
        #expect(store.herdrMainBot(on: f.destination) === f.main)
        #expect(store.herdrMainBot(on: f.source) == nil)
        #expect(store.herdrCarrySource(for: f.main) != nil)
        #expect(store.herdrCarrySource(for: f.analyst) != nil)
        #expect(f.main.messages.map(\.id) == messageIDs)
        #expect(record.cleanup.stopped == 2)
        #expect(f.ended == ["/api/agents/main-agent/42/end", "/api/agents/analyst-agent/42/end"])
        #expect(store.herdrServer(for: f.writer) == f.source)
        #expect(store.herdrTemplate(for: f.writer) == "codex-local")
        #expect(store.herdrModel(for: f.writer) == "local-only")
        #expect(store.herdrProjects(for: f.writer) == [f.project])
        #expect(store.herdrCarryOver(for: f.writer) == nil)
    }

    @Test func movingAStaleDuplicateDoesNotGiveItTheMainRole() async throws {
        let f = Fixture()
        f.analyst.canManageBots = true
        let record = try await f.move([f.analyst], stop: false)
        #expect(f.store.herdrServer(for: f.analyst) == f.destination)
        #expect(f.store.herdrMainBot(on: f.destination) == nil)
        #expect(f.store.herdrMainBot(on: f.source) === f.main)
        try await f.store.undoHerdrMove(record)
        #expect(f.store.herdrServer(for: f.analyst) == f.source)
        #expect(!f.store.createsHerdrBots(f.analyst))
        #expect(f.store.herdrMainBot(on: f.source) === f.main)
    }

    @Test(arguments: [false, true])
    func movingTheMainClearsStaleFlagsAndUndoRespectsANewChoice(chooseNewMain: Bool) async throws {
        let f = Fixture()
        f.analyst.canManageBots = true
        try f.store.saveThrowing()
        let record = try await f.move([f.main], stop: false)
        #expect(f.store.herdrMainBot(on: f.source) == nil && !f.analyst.canManageBots)
        #expect(f.store.herdrMainBot(on: f.destination) === f.main)
        let saved = try StoreFile.decode(Data(contentsOf: f.store.fileURL))
        #expect(saved.bots.filter(\.canManageBots).map(\.id) == [f.main.id])

        if chooseNewMain {
            f.store.setCanManageBots(f.writer, true)
            await #expect(throws: HerdrMoveError.mainChanged) { try await f.store.undoHerdrMove(record) }
            #expect(f.store.herdrMainBot(on: f.source) === f.writer)
            #expect(f.store.herdrMainBot(on: f.destination) === f.main)
        } else {
            try await f.store.undoHerdrMove(record)
            #expect(f.store.herdrMainBot(on: f.source) === f.main && !f.analyst.canManageBots)
            #expect(f.store.herdrMainBot(on: f.destination) == nil)
        }
    }

    @Test func explicitChoiceAndUndoRestoreAllOriginalSettings() async throws {
        let f = Fixture(), store = f.store
        store.defaults.set("codex-local", forKey: HerdrBackend.templateKey)
        store.setHerdrTemplate("", for: f.analyst)
        let destinationMain = Bot(name: "VPS Main", backend: .herdr)
        store.bots.append(destinationMain)
        store.setHerdrServer(f.destination.id, for: destinationMain)
        store.setCanManageBots(destinationMain, true)
        let record = try await f.move([f.main, f.analyst, f.writer], mapping: .one(template: "codex-vps", model: "terra"),
                                      history: false, stop: false)
        #expect(record.changes.count == 3)
        for bot in [f.main, f.analyst, f.writer] {
            #expect(store.herdrServer(for: bot) == f.destination)
            #expect(store.herdrTemplate(for: bot) == "codex-vps")
            #expect(store.herdrModel(for: bot) == "terra")
            #expect(store.herdrCarryOver(for: bot) == nil)
        }
        let destination = try await store.herdrClient(for: f.destination).workspace()
        let handoffs = try await store.prepareDirectModel(bot: f.main, server: f.destination, template: "codex-vps", model: "terra", in: destination)
        #expect(handoffs.isEmpty)
        #expect(store.herdrCarryOver(for: f.main) == nil)
        #expect(store.herdrMainBot(on: f.destination) === destinationMain)
        #expect(!f.main.canManageBots)
        #expect(f.ended.isEmpty)

        try await store.undoHerdrMove(record)
        #expect(store.herdrServer(for: f.main) == f.source)
        #expect(store.herdrServer(for: f.analyst) == f.source)
        #expect(store.herdrServer(for: f.writer) == f.source)
        #expect(store.herdrMainBot(on: f.source) === f.main)
        #expect(store.herdrMainBot(on: f.destination) === destinationMain)
        #expect(store.herdrTemplate(for: f.main) == "claude-local")
        #expect(store.herdrModel(for: f.main) == "sonnet")
        #expect(store.defaults.string(forKey: HerdrBackend.botTemplateKey(f.analyst.id)) == nil)
        #expect(store.herdrTemplate(for: f.analyst) == "codex-local")
        #expect(store.herdrModel(for: f.analyst) == "sol")
        #expect(store.herdrTemplate(for: f.writer) == "codex-local")
        #expect(store.herdrModel(for: f.writer) == "local-only")
        #expect(store.herdrProjects(for: f.main) == [f.project])
        #expect(store.herdrProjects(for: f.writer) == [f.project])
        await #expect(throws: HerdrMoveError.undoUnavailable) { try await store.undoHerdrMove(record) }
    }

    @Test func anActiveMoveRequiresTheReceiptOfTheSameSourceLaunch() async throws {
        let f = Fixture(remoteWorking: true)
        let request = ChatMessage(role: .user, content: "Continue my unfinished report")
        let reply = ChatMessage(role: .assistant, content: "Finished the first section.", isStreaming: true)
        f.analyst.messages = [request, reply]
        _ = f.store.beginTurn(in: f.analyst, bot: f.analyst, assistant: reply)
        let roster = try await f.store.herdrMoveWorkspace(on: f.source)
        let live = try #require(roster.agents.first { $0.address == "analyst-agent" })
        func checkpoint() -> MoveCheckpoint? {
            f.store.moveCheckpoint(for: f.analyst, agents: [live], workspace: roster)
        }
        #expect(checkpoint() == nil)
        func record(_ created: UInt64) {
            reply.deliveryReceipt = .init(server: f.source.id, turn: .init(core: "this-mac", address: live.address,
                createdMs: created, after: 0, launched: false), text: request.content)
        }
        record(live.createdMs + 1)
        #expect(checkpoint() == nil)
        record(live.createdMs)
        #expect(checkpoint()?.request.id == request.id)
    }

    @Test func streamingTurnStaysOnTheSourceAndIsNeverStopped() async throws {
        let f = Fixture(), store = f.store
        let turn = store.beginTurn(in: f.analyst, bot: f.analyst, assistant: nil)
        let record = try await f.move([f.main, f.analyst])
        #expect(record.skipped == [f.analyst.name])
        #expect(store.herdrServer(for: f.analyst) == f.source)
        #expect(store.turn(in: f.analyst) === turn)
        #expect(store.herdrTemplate(for: f.analyst) == "codex-local")
        #expect(store.herdrCarryOver(for: f.analyst) == nil)
        #expect(store.herdrServer(for: f.main) == f.destination)
        #expect(f.ended == ["/api/agents/main-agent/42/end"])
    }

    @Test func undoCarriesChatBackWhenTheOriginalDirectAgentWasStopped() async throws {
        let f = Fixture(), store = f.store
        let record = try await f.move([f.main, f.writer], history: false, stop: true)
        #expect(f.ended == ["/api/agents/main-agent/42/end"])
        #expect(store.herdrMoveSkipsCarry(f.main))
        #expect(store.herdrCarrySource(for: f.main) == nil)

        try await store.undoHerdrMove(record)
        #expect(!store.herdrMoveSkipsCarry(f.main))
        #expect(store.herdrMoveSkipsCarry(f.writer))
        let source = try await store.herdrClient(for: f.source).workspace()
        let sources = try await store.prepareDirectModel(bot: f.main, server: f.source, template: "claude-local", model: "sonnet", in: source)
        #expect(sources.count == 1)
        #expect(sources.first?.read == nil)
        #expect(store.herdrCarryLines(of: f.main).map(\.text) == ["My timezone is UTC.", "I’ll remember UTC."])
    }

    @Test func workStartedOutsideTheAppStaysOnTheSource() async throws {
        let f = Fixture(remoteWorking: true)
        let record = try await f.move([f.analyst])
        #expect(record.changes.isEmpty)
        #expect(record.skipped == [f.analyst.name])
        #expect(f.store.herdrServer(for: f.analyst) == f.source)
        #expect(f.ended.isEmpty)
    }

    @Test func undoDoesNotOverwriteChangesMadeAfterMoving() async throws {
        let f = Fixture()
        let record = try await f.move([f.main, f.analyst], stop: false)
        f.store.setHerdrModel("terra", for: f.analyst)
        await #expect(throws: HerdrMoveError.undoUnavailable) { try await f.store.undoHerdrMove(record) }
        #expect(f.store.herdrServer(for: f.main) == f.destination)
        #expect(f.store.herdrServer(for: f.analyst) == f.destination)
        #expect(f.store.herdrModel(for: f.analyst) == "terra")
    }
}

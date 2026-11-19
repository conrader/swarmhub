import Foundation
import Testing
@testable import AgentApp

// Several Herdr servers, moving bots to Herdr, and a Herdr bot that creates bots. The setup wizard: `SetupWizardTests`.

@MainActor private func herdrStore(_ defaults: UserDefaults = isolatedDefaults(), keys: InMemoryKeyStore = InMemoryKeyStore()) -> AppStore {
    AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: keys, defaults: defaults)
}

private let boxServer = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com", sshUser: "deploy", sshKeyPath: "~/.ssh/id_box")

@Test func herdrServerListMigratesSilently() {
    let fresh = HerdrServerList.servers(json: nil, legacyAddress: nil)
    #expect(fresh == [HerdrServer(id: "default", name: "This Mac", kind: .local, address: "http://127.0.0.1:8787")] && fresh[0].keyAccount == "herdr")
    let old = HerdrServerList.servers(json: nil, legacyAddress: "http://127.0.0.1:9000")
    #expect(old.count == 1 && old[0].id == "default" && old[0].kind == .address && old[0].port == 9000 && old[0].keyAccount == "herdr")
    let saved = HerdrServerList.servers(json: HerdrServerList.json(old + [boxServer]), legacyAddress: "http://ignored:1")
    #expect(saved == old + [boxServer] && saved[1].keyAccount == "herdr.box1" && saved[1].place == "deploy@box.example.com")
    #expect(HerdrServerList.servers(json: "not json", legacyAddress: nil) == fresh && HerdrServerList.servers(json: "[]", legacyAddress: nil) == fresh)
    #expect(HerdrServerList.server(bound: "gone", in: saved)?.id == "default" && HerdrServerList.server(bound: "box1", in: saved)?.id == "box1")
}

/// The forward uses the same port on both ends (the bridge checks it), passes the key file's path and never a key,
/// and refuses a host that ssh could read as an option.
@Test func herdrTunnelArgumentsAreSafe() {
    let forward = HerdrTunnel.forwardArguments(for: boxServer, home: "/Users/me") ?? []
    #expect(forward.starts(with: ["-N", "-L", "127.0.0.1:8787:127.0.0.1:8787", "-o", "ExitOnForwardFailure=yes"]) && forward.suffix(2) == ["--", "box.example.com"])
    #expect(forward.contains("BatchMode=yes") && forward.contains("/Users/me/.ssh/id_box") && forward.contains("IdentitiesOnly=yes") && forward.contains("deploy"))
    var hostile = boxServer; hostile.sshHost = "-oProxyCommand=touch /tmp/x"
    #expect(HerdrTunnel.forwardArguments(for: hostile) == nil && !HerdrTunnel.isSafe(host: "a b") && !HerdrTunnel.isSafe(user: "-x"))
    #expect(HerdrTunnel.forwardArguments(for: HerdrServerList.servers(json: nil, legacyAddress: nil)[0]) == nil, "only an SSH server gets a forward")
    var draft = HerdrServerDraft(kind: .ssh); #expect(draft.problem != nil && draft.server(id: "n") == nil)
    draft.sshDestination = " box.example.com "; draft.port = "9001"
    #expect(draft.server(id: "n") == HerdrServer(id: "n", name: "box.example.com", kind: .ssh, address: "http://127.0.0.1:9001", sshHost: "box.example.com"))
    #expect(HerdrServerDraft(server: boxServer).server(id: "box1") == boxServer)
    #expect(HerdrTunnel.reason("Warning: Permanently added 'x' to the list of known hosts.\nme@x: Permission denied (publickey).\n") == "me@x: Permission denied (publickey).")
}

@Test func oneSSHFieldAcceptsTerminalDestinations() throws {
    var draft = HerdrServerDraft(kind: .ssh)
    for (input, host, user) in [("mini-m4", "mini-m4", ""), ("deploy@studio", "studio", "deploy"),
                                ("  ssh deploy@studio\n", "studio", "deploy"), ("2001:db8::1", "2001:db8::1", "")] {
        draft.sshDestination = input
        let server = try #require(draft.server(id: "test"))
        #expect(server.sshHost == host && server.sshUser == user && server.name == host)
    }
    for input in ["user@", "@studio", "a@b@studio", "ssh -p 2222 studio", "ssh studio ls", "-oSomething"] {
        draft.sshDestination = input
        #expect(draft.server(id: "test") == nil)
    }
}

@MainActor @Test func herdrStartersAreAddedPerServer() {
    let store = herdrStore()
    store.saveHerdrServer(store.herdrServers[0], token: "t"); store.saveHerdrServer(boxServer, token: "t")
    let starters = [HerdrStarter(template: "one", name: "Claude", title: "Claude Code on Herdr", model: "first-model"), HerdrStarter(template: "two", name: "Codex", title: "Codex on Herdr", model: nil)]
    let added = store.addHerdrStarters(starters, on: store.herdrServers[0])
    #expect(added.map(\.name) == ["Claude", "Codex"] && added.allSatisfy { $0.backend == .herdr && store.herdrServer(for: $0).id == "default" })
    #expect(store.herdrTemplate(for: added[0]) == "one" && store.herdrModel(for: added[0]) == "first-model" && store.herdrModel(for: added[1]).isEmpty)
    #expect(store.addHerdrStarters(starters, on: store.herdrServers[0]).isEmpty, "a program that has a bot on the server is skipped")
    let onBox = store.addHerdrStarters(starters, on: boxServer)
    #expect(onBox.map(\.title) == ["Claude Code on Herdr · Box", "Codex on Herdr · Box"] && onBox.allSatisfy { store.herdrServer(for: $0).id == "box1" })
    #expect(store.missingHerdrStarters(starters, on: boxServer).isEmpty)
}

@MainActor @Test func eachHerdrBotIsBoundToAServerWithItsOwnToken() throws {
    let keys = InMemoryKeyStore(), store = herdrStore(keys: keys)
    #expect(store.herdrServers.map(\.id) == ["default"] && !store.herdrConfigured)
    let first = Bot(name: "One", backend: .herdr), second = Bot(name: "Two", backend: .herdr)
    store.bots = [first, second]
    store.saveHerdrServer(store.herdrServers[0], token: "token-one")
    store.saveHerdrServer(boxServer, token: "token-two")
    #expect(store.herdrServers.map(\.id) == ["default", "box1"] && store.herdrConfigured)
    #expect(keys.key(for: "herdr") == "token-one" && keys.key(for: "herdr.box1") == "token-two")
    #expect(store.herdrServer(for: second).id == "default", "a bot starts on the first server")
    store.setHerdrServer("box1", for: second)
    #expect(store.herdrServer(for: second) == boxServer && store.herdrBots(on: boxServer).map(\.name) == ["Two"] && store.connection(of: second) == "herdr:box1")
    let onDefault = try store.herdrBackend(for: first).client, onBox = try store.herdrBackend(for: second).client
    #expect(onDefault.token == "token-one" && onBox.token == "token-two")
    #expect(onBox.prepare != nil && onDefault.prepare == nil, "only an SSH server opens a forward")
    store.removeHerdrServer(boxServer)
    #expect(store.herdrServers.map(\.id) == ["default"] && store.herdrServer(for: second).id == "default" && keys.key(for: "herdr.box1").isEmpty)
    store.removeHerdrServer(store.herdrServers[0])
    #expect(store.herdrServers.count == 1, "the last server stays")
}

@MainActor @Test func herdrBotRequestsAreReadFromAReply() {
    let reply = """
    I proposed two bots.

    ```swarmhub
    [{"op":"create_bot","name":" Research ","instructions":"You find sources.","avatar":{"shape":"Star","color":"blue"},"runtime":"Codex"},
     {"op":"create_bot","name":"research"}, {"op":"create_bot","name":""}, {"op":"bot_created","name":"other"},
     {"op":"create_bot","name":"Writer","instructions":"You write."}]
    ```
    """
    #expect(HerdrBotRequest.requests(in: reply) == [HerdrBotRequest(name: "Research", instructions: "You find sources.", shape: "star", colour: "blue", runtime: "Codex"),
                                                   HerdrBotRequest(name: "Writer", instructions: "You write.")])
    #expect(SwarmhubBlock.visibleText(reply) == "I proposed two bots.", "the chat hides the block")
    for none in ["no block", "```swarmhub\n{\"op\":\"create_bot\",\"name\":\"Half\"", "```swarmhub\nnot json\n```", "```json\n{\"op\":\"create_bot\",\"name\":\"X\"}\n```"] {
        #expect(HerdrBotRequest.requests(in: none).isEmpty, "\(none)")
    }
    let note = AppStore.herdrCreationNote
    #expect(HerdrBotRequest.requests(in: note).map(\.name) == ["Research"] && note.utf8.count < 2_400 && note.contains(HerdrBotRequest.marker), "the note's own example is a valid request")
    let templates = [HerdrClient.Template(name: "one", description: nil, error: nil, runtime: .init(harness: "Claude Code", provider: nil, model: nil)),
                     HerdrClient.Template(name: "two", description: nil, error: nil, runtime: .init(harness: "Codex", provider: nil, model: nil))]
    #expect(HerdrBotRequest.template(for: "codex", in: templates)?.name == "two" && HerdrBotRequest.template(for: "Claude", in: templates)?.name == "one" && HerdrBotRequest.template(for: "none", in: templates) == nil)
}

@MainActor @Test func aHerdrBotCreatesBotsOnlyAfterConfirmation() throws {
    let store = herdrStore()
    store.saveHerdrServer(store.herdrServers[0], token: "t"); store.saveHerdrServer(boxServer, token: "t")
    let jarvis = Bot(name: "Jarvis", backend: .herdr), taken = Bot(name: "Writer", backend: .herdr)
    store.bots = [jarvis, taken]
    store.setHerdrServer("box1", for: jarvis); store.setHerdrServer("box1", for: taken); store.setHerdrTemplate("one", for: jarvis); store.setHerdrModel("own-model", for: jarvis)
    let block = "Proposed.\n\n```swarmhub\n[{\"op\":\"create_bot\",\"name\":\"Research\",\"instructions\":\"You find sources.\",\"avatar\":{\"shape\":\"star\",\"colour\":\"blue\"}},{\"op\":\"create_bot\",\"name\":\"Writer\"}]\n```"
    jarvis.messages = [ChatMessage(role: .user, content: "Create a new bot called Research"), ChatMessage(role: .assistant, content: block)]
    let before = try store.herdrBackend(for: jarvis)
    #expect(store.pendingHerdrBots(for: jarvis).isEmpty && before.creationNote == nil, "nothing is offered until the bot may create bots")
    store.setCanManageBots(jarvis, true)
    #expect(jarvis.canManageBots && store.createsHerdrBots(jarvis))
    let backend = try store.herdrBackend(for: jarvis)
    #expect(backend.creationNote == AppStore.herdrCreationNote && backend.launchInstructions?.contains("create_bot") == true)
    let pending = store.pendingHerdrBots(for: jarvis)
    #expect(pending.map(\.request.name) == ["Research", "Writer"] && pending.map(\.taken) == [false, true])
    #expect(store.bots.count == 2, "reading a request creates nothing")
    #expect(store.createHerdrBot(pending[1], manager: jarvis) == nil && store.bots.count == 2, "a taken name is not created")
    let created = try #require(store.createHerdrBot(pending[0], manager: jarvis))
    #expect(created.name == "Research" && created.persona == "You find sources." && created.backend == .herdr && created.avatarMark == AvatarMark(shape: "star", colour: "blue"))
    #expect(store.herdrServer(for: created).id == "box1" && store.herdrTemplate(for: created) == "one" && store.herdrModel(for: created) == HerdrModelChoice.recommended, "a new bot inherits the agent program and follows its recommended model")
    #expect(store.pendingHerdrBots(for: jarvis).isEmpty && jarvis.messages.last?.content == "Jarvis created Research")
    // Another agent program by name, on the model the server lists first.
    jarvis.messages.append(ChatMessage(role: .assistant, content: "```swarmhub\n{\"op\":\"create_bot\",\"name\":\"Coder\",\"runtime\":\"Codex\"}\n```"))
    let templates = [HerdrClient.Template(name: "two", description: nil, error: nil, runtime: .init(harness: "Codex", provider: nil, model: nil))]
    let wanted = try #require(store.pendingHerdrBots(for: jarvis).first)
    let coder = try #require(store.createHerdrBot(wanted, manager: jarvis, templates: templates, offered: [.init(id: "first-model", label: nil)]))
    #expect(store.herdrTemplate(for: coder) == "two" && store.herdrModel(for: coder) == HerdrModelChoice.recommended && coder.persona == Bot.defaultPersona)
    jarvis.messages.append(ChatMessage(role: .assistant, content: "```swarmhub\n{\"op\":\"create_bot\",\"name\":\"Extra\"}\n```"))
    let extra = try #require(store.pendingHerdrBots(for: jarvis).first)
    store.dismissHerdrBot(extra)
    #expect(store.pendingHerdrBots(for: jarvis).isEmpty && !store.bots.contains { $0.name == "Extra" }, "a dismissed request is gone and nothing was created")
}

/// An imported template becomes a Herdr bot, and its report promises nothing a Herdr agent does not do.
@MainActor @Test func anImportedTemplateBecomesAHerdrBot() throws {
    let store = herdrStore()
    let manifest = try GrokTemplateParser.parse(Data(#"{"name":"Garden","slug":"garden","instructions":"You tend the garden.","routines":[{"name":"Water","prompt":"Water it","schedule":"0 8 * * *"}],"skills":[{"name":"Pruning","markdown":"Cut back."}]}"#.utf8))
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let plan = TemplateImportMapper.makePlan(from: manifest)
    #expect(plan.report.contains { $0.name == "Herdr agent" && $0.status == .mapped })
    #expect(plan.report.contains { $0.name == "Water" && $0.status == .skipped } && plan.report.contains { $0.name == "Pruning" && $0.status == .skipped })
    let bot = store.importTemplate(plan)
    #expect(bot.backend == .herdr && bot.name == "Garden" && bot.persona == "You tend the garden." && store.herdrServer(for: bot).id == HerdrServer.defaultID)
    #expect(store.bots.first === bot && store.selectedBot === bot)
}

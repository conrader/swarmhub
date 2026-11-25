import AppKit
import Foundation
import Testing
@testable import AgentApp

// The setup wizard: where bots run, Connect, the main bot and the optional bots, its one write, and where it opens.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor private func wizardStore(_ defaults: UserDefaults = isolatedDefaults(), keys: InMemoryKeyStore = InMemoryKeyStore()) -> AppStore {
    AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: keys, defaults: defaults)
}

private let boxServer = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com", sshUser: "deploy")
private func model(_ id: String, _ label: String? = nil) -> HerdrClient.Template.Model { .init(id: id, label: label) }
/// Two agent programs by the server's own names; the first lists three models, the second none it can name.
private let programOne = HerdrProgram(template: "one", name: "Program One", takesModel: true, models: [model("first-model", "First"), model("second-model", "Second")])
private let programTwo = HerdrProgram(template: "two", name: "Program Two", takesModel: true, models: [model("other-model")])
private let serverOffer = HerdrOffer(programs: [programOne, programTwo], running: ["someone-abc123"])

@Test func thisMacWithNothingRunningAndAServerWithNoProgramStayOnConnect() {
    var flow = SetupFlow(); flow.apply(.pickHerdr(.local)); flow.apply(.herdrTest(.nothingHere(port: 8787)))
    #expect(flow.step == .herdr && flow.herdrNothingHere == 8787 && !flow.herdrReady, "a Mac with no Herdr running stays on the screen that says how to start one")
    flow.apply(.herdrTest(.connected(server: boxServer, key: nil, offer: HerdrOffer())))
    #expect(flow.herdrNoPrograms && !flow.herdrReady, "a server with no agent program cannot run a bot")
    flow.apply(.advance); #expect(flow.step == .herdr)
}

@Test func aServerWithOneProgramEndsOnTheMainBot() {
    var flow = SetupFlow(); flow.apply(.pickHerdr(.ssh)); flow.herdr.sshDestination = "box.example.com"
    flow.apply(.herdrTest(.connected(server: boxServer, key: nil, offer: HerdrOffer(programs: [programTwo])))); flow.apply(.advance)
    #expect(flow.step == .mainBot && flow.moreChoices.isEmpty && flow.isLastWizardStep && flow.mainBot.template == "two")
    flow.apply(.advance); #expect(flow.step == .mainBot, "there is no step after it")
}

@Test func aSavedServerStartsOnTheMainBotAndOffersToKeepItsMainBot() {
    var flow = SetupFlow(saved: boxServer)
    #expect(flow.step == .mainBot && flow.readsSavedServer && flow.canGoBack && !flow.mainBotReady && flow.herdr == HerdrServerDraft(server: boxServer))
    let jarvis = HerdrSetupBot(id: UUID(), name: "Jarvis", isMain: true, template: "one"), research = HerdrSetupBot(id: UUID(), name: "Research", isMain: false)
    flow.apply(.herdrTest(.connected(server: boxServer, key: nil, offer: serverOffer), bots: [jarvis, research]))
    #expect(flow.step == .mainBot && !flow.readsSavedServer && flow.keptMainBot == jarvis && flow.mainBotName == "Jarvis" && flow.mainBotReady, "its main bot stays unless the person says otherwise")
    #expect(flow.moreChoices == [programTwo], "the kept bot's program needs no second bot")
    flow.mainBot.keep = research.id; #expect(flow.keptMainBot == research && flow.moreChoices == [programTwo], "a bot with no program of its own starts from the server's first")
    flow.mainBot.keep = nil; flow.mainBot.name = "research"
    #expect(flow.mainBotProblem == WizardCopy.nameTaken("research") && !flow.mainBotReady, "a name already on the server is refused")
    flow.mainBot.name = "Ada"; #expect(flow.mainBotReady)
    flow.apply(.back); #expect(flow.step == .welcome && flow.herdrOffer == nil)
    // A saved server that cannot be read shows its own Connect screen, with the reason, and Back still leads to Welcome.
    var broken = SetupFlow(saved: boxServer); broken.apply(.herdrTest(.failed("down")))
    #expect(broken.step == .herdr && broken.herdrFailure == "down" && broken.herdr.sshDestination == "deploy@box.example.com")
    broken.apply(.herdrTest(.connected(server: boxServer, key: nil, offer: serverOffer))); broken.apply(.advance)
    #expect(broken.step == .mainBot); broken.apply(.back); broken.apply(.back); #expect(broken.step == .welcome)
}

@Test func theMainBotDraftFollowsWhatTheServerOffers() {
    var draft = HerdrMainBotDraft(); draft.template = "gone"; draft.model = "second-model"
    draft.begin(offer: serverOffer, bots: [])
    #expect(draft.template == "one" && draft.model.isEmpty && draft.avatar != .unpicked, "a program the server does not have falls back to its first")
    draft.model = "second-model"; draft.begin(offer: serverOffer, bots: []); #expect(draft.model == "second-model", "a model the server still offers stays")
    draft.model = "gone"; draft.begin(offer: serverOffer, bots: []); #expect(draft.model.isEmpty)
    let look = draft.avatar; draft.avatar = .mark(shape: "star", colour: "blue"); draft.begin(offer: serverOffer, bots: [])
    #expect(look != .unpicked && draft.avatar == .mark(shape: "star", colour: "blue"), "a chosen avatar stays")
}

@MainActor @Test func theWizardsLastButtonCreatesTheMainBotAndTheTickedBots() throws {
    let keys = InMemoryKeyStore(), store = wizardStore(keys: keys)
    store.bots = [Bot(name: "Sample", isDemo: true)]
    var draft = HerdrServerDraft(kind: .ssh); draft.sshDestination = "box.example.com"
    #expect(store.setupHerdrID(for: draft) == "default", "the first server takes the stand-in's place")
    let server = try #require(draft.server(id: store.setupHerdrID(for: draft)))
    var main = HerdrMainBotDraft(); main.begin(offer: serverOffer, bots: [])
    main.name = " Ada "; main.instructions = "You run my projects."; main.avatar = .mark(shape: "star", colour: "blue"); main.model = "second-model"
    #expect(throws: AppStore.SetupCommitError.notTested) { try store.commitSetupWizard(server: nil, key: nil, main: main, more: [], offer: serverOffer) }
    var unnamed = main; unnamed.name = " "
    #expect(throws: AppStore.SetupCommitError.nothingChosen) { try store.commitSetupWizard(server: server, key: nil, main: unnamed, more: [], offer: serverOffer) }
    #expect(store.bots.count == 1 && store.defaults.string(forKey: HerdrServer.listKey) == nil, "a refused commit leaves nothing behind")

    let ada = try store.commitSetupWizard(server: server, key: "read-from-server", main: main, more: [programTwo], offer: serverOffer)
    #expect(ada.name == "Ada" && ada.persona == "You run my projects." && ada.backend == .herdr && ada.avatarMark == AvatarMark(shape: "star", colour: "blue"))
    #expect(store.createsHerdrBots(ada) && store.herdrMainBot(on: server) === ada && store.herdrSteers(ada), "it is the server's main bot, and steers like every Herdr bot")
    #expect(store.herdrTemplate(for: ada) == "one" && store.herdrModel(for: ada) == "second-model")
    #expect(store.bots.map(\.name) == ["Ada", "Program Two"] && store.selectedBot === ada && !store.bots.contains(where: \.isDemo))
    let two = store.bots[1]
    #expect(two.backend == .herdr && !two.canManageBots && store.herdrTemplate(for: two) == "two" && store.herdrModel(for: two) == HerdrModelChoice.recommended, "an explicitly added bot uses its agent’s recommendation")
    #expect(store.herdrServers == [server] && keys.key(for: "herdr") == "read-from-server" && FirstRun.state(store.defaults) == .done)
    #expect(store.herdrLanding?.bot == ada.id && store.herdrFirstReplyHint(for: ada) == WizardCopy.firstReply("Ada"), "no agent runs for it yet, so the first reply takes longer")
    #expect(!FirstRun.needsWizard(defaults: store.defaults, bots: store.bots) && store.wizardStart().step == .welcome && store.setupAddsServer, "set up: the wizard now opens only to add a server")
    #expect(throws: AppStore.SetupCommitError.nothingChosen) { try store.commitSetupWizard(server: server, key: nil, main: main, more: [], offer: serverOffer) }
    #expect(store.bots.count == 2, "the same button twice makes no second main bot")
    ada.messages.append(ChatMessage(role: .user, content: "hi")); #expect(store.herdrFirstReplyHint(for: ada) == nil, "the line is gone with the first message")
    #expect(store.setupHerdrID(for: draft) == "default", "the same place again updates its server")

    // Again on the same server: the main bot is offered to stay, and keeping it adds nothing.
    let bots = store.setupHerdrBots(on: server)
    #expect(bots.map(\.name) == ["Ada", "Program Two"] && bots.map(\.isMain) == [true, false] && bots.map(\.template) == ["one", "two"])
    var again = HerdrMainBotDraft(); again.begin(offer: serverOffer, bots: bots)
    #expect(again.keep == ada.id)
    #expect(try store.commitSetupWizard(server: server, key: nil, main: again, more: [], offer: serverOffer) === ada && store.bots.count == 2 && store.createsHerdrBots(ada))
    // Another bot of the server takes the role; the main bot before it loses it, so there is one per server.
    again.keep = two.id
    let running = HerdrOffer(programs: serverOffer.programs, running: [HerdrBackend.agentName(botName: two.name, botID: two.id)])
    #expect(try store.commitSetupWizard(server: server, key: nil, main: again, more: [], offer: running) === two && store.createsHerdrBots(two) && !store.createsHerdrBots(ada))
    #expect(store.herdrLanding == nil, "its agent already runs, so the chat is not marked for the line about a slower first reply")
    // A new main bot beside them.
    var third = HerdrMainBotDraft(); third.begin(offer: serverOffer, bots: store.setupHerdrBots(on: server)); third.keep = nil; third.name = "Grace"
    let grace = try store.commitSetupWizard(server: server, key: nil, main: third, more: [], offer: serverOffer)
    #expect(store.bots.first === grace && store.herdrMainBot(on: server) === grace && !store.createsHerdrBots(two) && grace.persona == Bot.defaultPersona && store.herdrModel(for: grace) == HerdrModelChoice.recommended)
}

@MainActor @Test func theWizardOpensOnTheMainBotOfAServerThatHasNone() {
    let store = wizardStore()
    #expect(store.wizardStart().step == .welcome && !store.setupAddsServer, "nothing set up: where bots run")
    store.saveHerdrServer(store.herdrServers[0], token: "t"); store.saveHerdrServer(boxServer, token: "t")
    let first = store.wizardStart()
    #expect(first.step == .mainBot && first.readsSavedServer && first.herdr.kind == .local && !store.setupAddsServer, "a server that is set up skips Connect")
    let jarvis = Bot(name: "Jarvis", backend: .herdr); store.bots = [jarvis]; jarvis.canManageBots = true
    #expect(store.wizardStart().herdr.sshDestination == "deploy@box.example.com", "the first server without a main bot")
    let other = Bot(name: "Other", backend: .herdr); store.bots.append(other); store.setHerdrServer("box1", for: other); other.canManageBots = true
    #expect(store.wizardStart().step == .welcome && store.setupAddsServer, "every server has its main bot: the wizard adds a server")
    #expect(store.setupHerdrBots(on: boxServer) == [HerdrSetupBot(id: other.id, name: "Other", isMain: true, template: nil)])
    // The stand-in for a list that was never saved is found by its place, so "This Mac" keeps the id the launch token belongs to.
    let fresh = wizardStore()
    #expect(fresh.setupHerdrID(for: HerdrServerDraft(kind: .local)) == HerdrServer.defaultID)
    var elsewhere = HerdrServerDraft(kind: .local); elsewhere.port = "9001"
    #expect(fresh.setupHerdrID(for: elsewhere) == HerdrServer.defaultID, "nothing is set up yet, so the first server takes the stand-in's place")
}

/// A setup window the system brings back at launch closes itself; one that was asked for, and a render, stay.
@MainActor @Test func aSetupWindowNobodyAskedForDoesNotStay() {
    #expect(SetupView.cameBackUnasked(preset: nil, generation: 0), "shown before anything in this run asked for it")
    #expect(!SetupView.cameBackUnasked(preset: nil, generation: 1) && !SetupView.cameBackUnasked(preset: SetupFlow(), generation: 0))
    let store = wizardStore()
    #expect(store.setupGeneration == 0, "a launch has asked for nothing yet")
}

/// Every failure of Connect is told apart, in the setup window's words.
@Test func connectSaysWhatIsWrong() {
    let typed = HerdrServer(id: "t", name: "127.0.0.1", kind: .address, address: "http://127.0.0.1:8787")
    func line(_ error: Error, _ server: HerdrServer = typed, readingKey: Bool = false) -> String { HerdrSetupProblem.of(error, readingKey: readingKey).line(for: server) }
    #expect(HerdrSetupProblem.of(HerdrClient.Failure.unauthorized) == .wrongKey && line(HerdrClient.Failure.unauthorized).contains("did not accept the access key"))
    #expect(HerdrSetupProblem.of(URLError(.cannotConnectToHost)) == .unreachable && line(URLError(.timedOut)).contains("not reachable"))
    #expect(HerdrSetupProblem.of(HerdrClient.Failure.http(503, "Cannot reach Herdr Core.")) == .noCore && line(HerdrSetupProblem.noCore).contains("Herdr Core is not running"))
    #expect(line(HerdrSetupProblem.noPrograms).contains("no AI is set up"))
    #expect(HerdrSetupProblem.of(HerdrClient.Failure.http(500, "boom")) == .other("boom") && line(HerdrClient.Failure.refusedHost) == HerdrClient.Failure.refusedHost.localizedDescription)
    #expect(HerdrSetupProblem.of(BackendError.unavailable(HerdrBackend.missingToken)) == .noKey && line(BackendError.unavailable("else")) == "else")
    #expect(line(HerdrTunnel.Failure.ended("deploy@box: Permission denied (publickey)."), boxServer).hasPrefix("box.example.com refused the login"))
    #expect(line(HerdrTunnel.Failure.ended("ssh: Could not resolve hostname box.example.com: nodename nor servname provided"), boxServer) == "No server named box.example.com was found. Check the name.")
    #expect(line(HerdrTunnel.Failure.ended("ssh: connect to host box.example.com port 22: Operation timed out"), boxServer).contains("not reachable over SSH"))
    #expect(HerdrSetupProblem.of(HerdrTunnel.Failure.ended("cat: /home/deploy/.config/swarmhub-herdr/token: No such file or directory"), readingKey: true) == .sshNoService)
    #expect(HerdrSetupProblem.of(HerdrTunnel.Failure.ended("cat: x: No such file or directory")) == .sshFailed("cat: x: No such file or directory"), "only while the key file was being read")
    #expect(HerdrSetupProblem.of(HerdrTunnel.Failure.timedOut) == .sshNoAnswer && line(HerdrTunnel.Failure.timedOut, boxServer).contains("nothing answers on its port 8787"))
    let all: [HerdrSetupProblem] = [.unreachable, .sshFailed("x"), .sshNoService, .sshNoAnswer, .noKey, .wrongKey, .noCore, .noPrograms]
    let lines = all.flatMap { problem in [typed, boxServer, HerdrServerList.servers(json: nil, legacyAddress: nil)[0]].map { problem.line(for: $0) } }
    #expect(Set(all.map { $0.line(for: typed) }).count == all.count && !lines.contains { $0.localizedCaseInsensitiveContains("token") }, "each has its own line, and the wizard says access key")
}

@Test func theOfferNamesProgramsAndModelsAsTheServerDoes() {
    let again = HerdrProgram(template: "two-next", name: "Program Two", takesModel: true, models: [])
    let offer = HerdrOffer(programs: [programOne, programTwo, again], running: ["jarvis-abc123"])
    #expect(programOne.defaultModel == model("first-model", "First") && HerdrProgram.modelName(model("other-model")) == "other-model" && again.defaultModel == nil)
    #expect(offer.label(programOne) == "Program One" && offer.label(again) == "Program Two · two-next" && offer.names == "Program One and Program Two")
    #expect(!offer.startsAgent(named: "renamed-abc123") && offer.startsAgent(named: "jarvis-ffffff"))
    #expect(offer.others(than: "one", taken: [], names: []).map(\.template) == ["two"] && offer.others(than: "two-next", taken: [], names: []).map(\.template) == ["one"])
    #expect(offer.others(than: "one", taken: ["two-next"], names: []).isEmpty && offer.others(than: "one", taken: [], names: ["program two"]).isEmpty)
}

/// The wizard's words name no older software, no agent program and no model, and say "access key".
@Test func theWizardsWordsArePlain() throws {
    let lower = WizardCopy.all.map { $0.lowercased() }
    for word in ["token", "mock", "keychain", "template"] { #expect(!lower.contains { $0.contains(word) }, "the wizard says \(word)") }
    #expect(WizardCopy.steps.count == 4 && WizardCopy.stepLabel(2) == "Step 3 of 4: Main bot" && !WizardCopy.all.contains(""))
    #expect(WizardCopy.addBots(1) == "Add 1 bot" && WizardCopy.createBots(3) == "Create 3 bots" && WizardCopy.canRun("One", count: 1) == "Your bots can run on One.")
    // The wizard's views take their words from the copy enums, like the rest of the setup window.
    let literal = try NSRegularExpression(pattern: #"(\b(Text|Button|Label|TextField|SecureField|Toggle|Picker|Section|DisclosureGroup|LabeledContent)|\.help)\(\s*""#)
    let text = try String(contentsOf: repoRoot.appending(path: "Sources/AgentApp/Setup/SetupHerdrSteps.swift"), encoding: .utf8)
    #expect(literal.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 0, "SetupHerdrSteps.swift passes a string literal to a control")
}

@Test func remoteSetupIsOfferedOnlyForTheTestedDestination() throws {
    var flow = SetupFlow()
    flow.apply(.pickHerdr(.ssh))
    flow.herdr.sshDestination = "qa@box.example.com"
    let server = try #require(flow.herdr.server(id: "qa-server"))
    flow.apply(.herdrTest(.sshSetupAvailable(server, .sshNoService)))
    #expect(flow.sshSetupTarget == server)
    flow.herdr.sshDestination = "qa@another.example.com"
    #expect(flow.sshSetupTarget == nil)
    flow.herdr.sshDestination = "qa@box.example.com"
    flow.apply(.herdrTest(.failed(HerdrSetupProblem.wrongKey.line(for: server))))
    #expect(flow.sshSetupTarget == nil)
    flow.apply(.herdrTest(.sshLoginRequired(server)))
    #expect(flow.sshSetupTarget == nil)
}

@Test func theWizardGoesFromWhereToConnectToTheMainBotToMoreBots() {
    var flow = SetupFlow()
    #expect(flow.step == .welcome && flow.place == .local, "This Mac is selected to begin with")
    flow.place = .ssh; flow.apply(.pickHerdr(flow.place))
    #expect(flow.step == .herdr && flow.herdr.kind == .ssh && flow.canGoBack && !flow.herdrReady)
    flow.herdr.sshDestination = "box.example.com"
    flow.apply(.herdrTest(.failed("no"))); #expect(flow.step == .herdr && flow.herdrFailure == "no" && !flow.herdrReady)
    flow.apply(.advance); #expect(flow.step == .herdr, "Continue does nothing until Test has passed")
    flow.apply(.herdrTest(.connected(server: boxServer, key: "k", offer: serverOffer)))
    #expect(flow.step == .herdr && flow.herdrReady && flow.herdrServer == boxServer && flow.herdrKey == "k", "a passed Test stays on Connect and shows its result")
    flow.herdr.sshDestination = "other@box.example.com"; #expect(!flow.herdrReady, "a result only counts for the fields it was tested with")
    flow.herdr.sshDestination = "box.example.com"; flow.apply(.advance)
    #expect(flow.step == .mainBot && flow.mainBot.keep == nil && flow.mainBot.name == WizardCopy.suggestedName)
    #expect(flow.mainBot.template == "one" && flow.mainBot.model == HerdrModelChoice.recommended && flow.mainBotReady, "the first program uses its recommendation")
    #expect(flow.moreChoices.map(\.template) == ["two"] && !flow.isLastWizardStep)
    flow.mainBot.name = "  "; #expect(flow.mainBotProblem == WizardCopy.nameMissing && !flow.mainBotReady)
    flow.apply(.advance); #expect(flow.step == .mainBot, "a main bot without a name does not go on")
    flow.mainBot.name = "Ada"; flow.apply(.advance)
    #expect(flow.step == .moreBots && flow.moreBots.isEmpty && flow.moreChosen.isEmpty && flow.isLastWizardStep, "nothing is ticked, so nothing is added unasked")
    flow.moreBots = ["two"]; #expect(flow.moreChosen == [programTwo])
    flow.apply(.back); #expect(flow.step == .mainBot); flow.apply(.back); #expect(flow.step == .herdr && flow.herdrReady, "back on Connect the result still stands")
    flow.apply(.back); #expect(flow.step == .welcome && flow.herdrServer == nil && !flow.canGoBack)
}

/// Default suite: the wizard's screens render through the renderer's own environment, each differently.
@MainActor @Test func theWizardsStepsRender() async throws {
    let store = SetupPreview.makeStore(); store.isSetupPreview = false
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let flows = HeadlessHerdrShots.wizardFlows(server: boxServer, thisMac: store.herdrServers[0])
    #expect(flows.count == HeadlessHerdrShots.wizard.count - 1, "every shot but the chat is a state of the window")
    #expect(flows.map(\.step) == [.welcome, .welcome, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .herdr, .mainBot, .mainBot, .mainBot, .mainBot, .mainBot, .moreBots, .moreBots])
    var sizes: [Int] = []
    for index in [0, 4, 13, 18] {
        let data = try #require(await HeadlessSetup.png(SetupView(preset: flows[index]), store: store, updater: updater, size: HeadlessSetup.size))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide > 0 && data.count > 4_000, "\(HeadlessHerdrShots.wizard[index]) looks blank"); sizes.append(data.count)
    }
    #expect(Set(sizes).count == sizes.count)
    #expect(store.bots.isEmpty && store.defaults.string(forKey: HerdrServer.listKey) == nil, "showing the wizard writes nothing")
}

@Test func bothProgramsStartWithOneBotAndAnEditableRecommendation() {
    let codex = HerdrProgram(template: "cx", name: "Codex", takesModel: true, models: [model("other"), model("gpt-sol")])
    let claude = HerdrProgram(template: "cc", name: "Claude", takesModel: true, models: [model("opus"), model("sonnet")])
    let offer = HerdrOffer(programs: [claude, codex])
    var flow = SetupFlow()
    flow.starter = .both
    flow.apply(.pickHerdr(.local))
    flow.apply(.herdrTest(.connected(server: boxServer, key: nil, offer: offer)))
    #expect(flow.herdrReady && flow.moreChosen.isEmpty && flow.moreChoices.isEmpty)
    #expect(flow.mainBot.template == "cx" && flow.mainBot.model == HerdrModelChoice.recommended)
    flow.selectMainProgram(claude)
    #expect(flow.mainBot.template == "cc" && flow.moreChosen.isEmpty)
    #expect(HerdrModelChoice.suggested(program: "Claude Code", offered: claude.models)?.id == "sonnet")
    #expect(HerdrModelChoice.suggested(program: "Codex", offered: codex.models)?.id == "gpt-sol")
    #expect(HerdrModelChoice.suggested(program: "OpenCode", offered: [model("openrouter/qwen/example")]) == nil)
    flow.mainBot.model = "opus"
    flow.apply(.advance)
    #expect(flow.mainBot.model == "opus")
}


@Test func apiModelIDsKeepTheirProviderAndVendorSegments() {
    #expect(HerdrModelChoice.apiModelID(" openrouter/deepseek/deepseek-chat ") == "openrouter/deepseek/deepseek-chat")
    #expect(HerdrModelChoice.apiModelID("custom/qwen-coder") == "custom/qwen-coder")
    #expect(HerdrModelChoice.apiModelID("model without provider") == nil)
    #expect(HerdrModelChoice.apiModelID("openrouter/") == nil)
}

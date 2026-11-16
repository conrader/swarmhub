import AppKit
import SwiftUI

/// Herdr shots of `--render-setup` (alone with `--only herdr`): the setup window's Herdr path (where it runs, this Mac
/// with nothing running, SSH, address, starter agents), Settings → Servers and keys with two servers, the simple page,
/// a Herdr bot's and a Hermes bot's Advanced settings, a bot's request to create bots waiting above the composer, and
/// a bot's helper agents: under it in the sidebar, in its Details panel, one of them opened, a server's helper settings,
/// a request for a bot passed between a bot and the main bot: both chats, and the settings of a bot that is not the main bot,
/// and what a bot runs on by name: its Model tab, its Overview, and an agent program for which the server lists no models.
/// All synthetic and in memory: Test results are built here, no server has a token, nothing connects.
@MainActor enum HeadlessHerdrShots {
    static let names = ["herdr-s1-where", "herdr-s3-this-mac-nothing", "herdr-s3-ssh", "herdr-s3-ssh-failed", "herdr-s3-address", "herdr-s4-starters",
                        "herdr-settings-servers", "herdr-settings-simple", "herdr-editor-advanced", "herdr-editor-move", "herdr-bot-request",
                        "herdr-helpers-sidebar", "herdr-helpers-details", "herdr-helper-view", "herdr-helper-settings", "herdr-main-chat", "herdr-asker-chat", "herdr-editor-not-main", "herdr-model-tab", "herdr-model-overview", "herdr-model-no-list", "herdr-model-header"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let wizard = HeadlessSetup.size
        let box = HerdrServer(id: "box1", name: "Studio server", kind: .ssh, address: HerdrServer.loopback(port: HerdrServer.defaultPort), sshHost: "studio.example.com", sshUser: "deploy")

        var nothing = SetupFlow(); nothing.apply(.pickHerdr(.local)); nothing.apply(.herdrTest(.nothingHere(port: HerdrServer.defaultPort)))
        var ssh = SetupFlow(); ssh.apply(.pickHerdr(.ssh)); ssh.herdr.sshHost = "studio.example.com"; ssh.herdr.sshUser = "deploy"; ssh.herdr.sshKeyPath = "~/.ssh/id_ed25519"
        var failed = ssh; failed.apply(.herdrTest(.failed(HerdrTunnel.Failure.ended("deploy@studio.example.com: Permission denied (publickey).").localizedDescription)))
        var address = SetupFlow(); address.apply(.pickHerdr(.address)); address.herdr.address = "http://127.0.0.1:8787"
        let starters = [HerdrStarter(template: "starter-one", name: "Claude", title: "Claude Code on Herdr", model: nil), HerdrStarter(template: "starter-two", name: "Codex", title: "Codex on Herdr", model: nil)]
        var choose = ssh; choose.apply(.herdrTest(.connected(server: box, key: nil, starters: starters))); choose.preselect(alreadyAdded: [])
        for (name, flow) in [(names[0], SetupFlow()), (names[1], nothing), (names[2], ssh), (names[3], failed), (names[4], address), (names[5], choose)] {
            write(name, await png(AnyView(SetupView(preset: flow)), store, wizard))
        }

        store.saveHerdrServer(store.herdrServers[0], token: nil); store.saveHerdrServer(box, token: nil)
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", persona: "You run the team.", backend: .herdr); jarvis.canManageBots = true
        let infra = Bot(name: "Infra", title: "Boxes and backups", backend: .hermes, hermesProfile: "grok-infra")
        store.bots = [jarvis, infra]; store.setHerdrServer(box.id, for: jarvis)
        let settings = NSSize(width: 760, height: 1_560)
        write(names[6], await png(AnyView(Form { SettingsAccountPane(cache: store.botInfo) }.formStyle(.grouped).frame(width: settings.width, height: settings.height).background(AppColor.panel)), store, settings))
        write(names[7], await png(AnyView(SettingsSimplePane(openAdvanced: {})), store, HeadlessSetup.settingsSize))
        let editor = NSSize(width: 560, height: 980)
        for (name, bot) in [(names[8], jarvis), (names[9], infra)] {
            write(name, await png(AnyView(Form { BotEditorAdvancedSection(bot: bot, fields: .constant(BotEditorFields(bot: bot))) }.formStyle(.grouped)
                .frame(width: editor.width, height: editor.height).background(AppColor.panel)), store, editor))
        }
        let block = "```swarmhub\n[{\"op\":\"create_bot\",\"name\":\"Research\",\"instructions\":\"You find and check sources, and answer with links.\",\"avatar\":{\"shape\":\"star\",\"colour\":\"blue\"}},{\"op\":\"create_bot\",\"name\":\"Writer\",\"instructions\":\"You turn notes into clear drafts.\",\"runtime\":\"Codex\"}]\n```"
        jarvis.messages = [ChatMessage(role: .user, content: "Create two bots: one for research and one for writing."), ChatMessage(role: .assistant, content: "I proposed Research and Writer.\n\n" + block)]
        let card = NSSize(width: 760, height: 220)
        write(names[10], await png(AnyView(HerdrBotRequestCard(manager: jarvis).frame(width: card.width, height: card.height).background(AppColor.chat)), store, card))

        // Helpers as the server would list them: one working, one answered, one stopped at a prompt. The model is whatever the server said.
        let helpers = [HerdrClient.Helper(address: "t43", createdMs: 3, name: "tests", model: "server-model-b", difficulty: "medium", task: "Add tests for the CSV importer's quoted fields and make them pass.", state: "live", status: .init(state: "working"), answered: false),
                       HerdrClient.Helper(address: "t42", createdMs: 2, name: "rename", model: "server-model-a", difficulty: "easy", task: "Rename `fetchAll` to `loadAll` everywhere in Sources/.", state: "live", status: .init(state: "done"), answered: true,
                                          reply: .init(id: 9, text: "Renamed 14 call sites in 6 files; the build passes.")),
                       HerdrClient.Helper(address: "t41", createdMs: 1, name: "design", model: "server-model-c", difficulty: "hard", task: "Propose how the importer should report partial failures.", state: "live", status: .init(state: "blocked"), answered: false)]
        store.herdrHelpers[jarvis.id] = HerdrClient.Helpers(core: "core", parent: .init(address: "t40", createdMs: 0), limit: 3, stopAfterSeconds: 60, helpers: helpers)
        store.bots = [jarvis, Bot(name: "Research", title: "Sources and links", backend: .herdr), infra]
        let sidebar = NSSize(width: SidebarMetrics.width.ideal, height: 460)
        write(names[11], await png(AnyView(SidebarView(selection: .constant(jarvis)).frame(width: sidebar.width, height: sidebar.height)), store, sidebar))
        store.selectedBot = jarvis; store.infoTab = .overview
        write(names[12], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 760)))
        let log = HerdrClient.HelperLog(tools: [.init(seq: 1, tool: "Grep", detail: "fetchAll", finished: true, failed: false), .init(seq: 2, tool: "Edit", detail: "Sources/Importer/CSVReader.swift", finished: true, failed: false),
                                                .init(seq: 3, tool: "Bash", detail: "swift build", finished: true, failed: false)],
                                        screen: "● Renamed 14 call sites in 6 files; the build passes.\n\n✻ Worked for 41s\n────────────────────────────────────────\n❯ ")
        var shownLog = log; shownLog.replies = [.init(id: 9, kind: "reply", text: "Renamed **14 call sites** in 6 files; the build passes.\n\n- `CSVReader.swift`\n- `ImportQueue.swift`")]
        let opened = NSSize(width: 760, height: 720), choice = HerdrHelperSelection(botID: jarvis.id, helperID: helpers[1].id)
        store.openHerdrHelper = choice
        write(names[13], await png(AnyView(HerdrHelperView(bot: jarvis, selection: choice, helper: helpers[1], core: "core", log: shownLog).frame(width: opened.width, height: opened.height)), store, opened))
        // A server's helper settings as read: two agent programs, the models each lists, hard tasks not allowed yet.
        let programs = [HerdrClient.Template(name: "starter-one", description: nil, error: nil, runtime: .init(harness: "Claude Code", provider: nil, model: nil), modelAgent: "one"),
                        HerdrClient.Template(name: "starter-two", description: nil, error: nil, runtime: .init(harness: "Codex", provider: nil, model: nil), modelAgent: "two")]
        let offered: [String: [HerdrClient.Template.Model]] = ["starter-one": [.init(id: "server-model-a", label: "Server model A"), .init(id: "server-model-c", label: "Server model C")],
                                                              "starter-two": [.init(id: "server-model-b", label: "Server model B")]]
        let policy = HerdrHelperPolicy(maxRunning: 3, stopAfterSeconds: 60, stopUnansweredAfterSeconds: 1_800, difficulties: ["easy": .init(template: "starter-one", model: "server-model-a"), "medium": .init(template: "starter-two", model: "server-model-b")])
        let read = HerdrHelperPolicySection.Loaded(settings: .init(policy: policy, problem: nil, bounds: .init(maxRunning: .init(min: 0, max: 16), stopAfterSeconds: .init(min: 5, max: 86_400, default: 60), stopUnansweredAfterSeconds: .init(min: 60, max: 604_800, default: 1_800))), templates: programs, models: offered)
        let policySize = NSSize(width: 760, height: 520)
        write(names[14], await png(AnyView(Form { HerdrHelperPolicySection(server: box, named: true, preset: read) }.formStyle(.grouped).frame(width: policySize.width, height: policySize.height).background(AppColor.panel)), store, policySize))

        // A bot asks the main bot for a bot. Jarvis created one on its own decision (Remove, Keep) and left another to the person.
        let boppy = Bot(name: "Boppy", title: "Product", persona: "You look after the product.", backend: .herdr)
        let legal = Bot(name: "Legal", title: "Created by Jarvis", persona: "You review the contracts people send to the company and say what to change.", backend: .herdr)
        store.bots = [jarvis, boppy, legal, infra]
        for bot in [boppy, legal] { store.setHerdrServer(box.id, for: bot) }
        func relayed(_ text: String, _ kind: String, name: String) -> ChatMessage {
            ChatMessage(role: .user, content: text, metadata: [HerdrBotRelay.Key.kind: kind, HerdrBotRelay.Key.asker: boppy.id.uuidString.lowercased(), HerdrBotRelay.Key.name: name])
        }
        func fence(_ json: String) -> String { "```swarmhub\n\(json)\n```" }
        let wantsLegal = HerdrBotAsk(name: "Legal", purpose: "People keep sending me contracts to review, which is not product work."), wantsPayments = HerdrBotAsk(name: "Payments", purpose: "Pays supplier invoices from the company account.")
        jarvis.messages = [relayed(HerdrBotRelay.request(from: boppy.name, wantsLegal), HerdrBotRelay.request, name: "Legal"),
                           ChatMessage(role: .assistant, content: "A separate bot for contracts makes sense, so I created Legal.\n\n" + fence("{\"op\":\"create_bot\",\"decision\":\"decided\",\"name\":\"Legal\",\"instructions\":\"You review contracts.\"}")),
                           AppOnlyLine.line(AppOnlyLine.created.render(jarvis.name, legal.name)),
                           relayed(HerdrBotRelay.request(from: boppy.name, wantsPayments), HerdrBotRelay.request, name: "Payments"),
                           ChatMessage(role: .assistant, content: "A bot that moves money is yours to decide, so I proposed Payments.\n\n" + fence("{\"op\":\"create_bot\",\"decision\":\"ask\",\"name\":\"Payments\",\"instructions\":\"You prepare supplier payments and ask before each one.\",\"avatar\":{\"shape\":\"gem\",\"colour\":\"green\"}}"))]
        store.defaults.set([AppStore.herdrRequestID(jarvis.messages[1].id, HerdrBotRequest(name: "Legal"))], forKey: AppStore.herdrHandledRequestsKey)
        store.setHerdrUnasked(legal, by: jarvis)
        boppy.messages = [ChatMessage(role: .user, content: "Contracts are not your job. Get a bot for that."),
                          ChatMessage(role: .assistant, content: "Agreed. I asked the main bot for one.\n\n" + fence("{\"op\":\"request_bot\",\"name\":\"Legal\",\"purpose\":\"\(wantsLegal.purpose)\"}")),
                          AppOnlyLine.line(AppOnlyLine.botAskPassedOn.render(boppy.name, "Legal", jarvis.name)),
                          relayed(HerdrBotRelay.answer(from: jarvis.name, [.created("Legal")]), HerdrBotRelay.outcome, name: "Legal"),
                          ChatMessage(role: .assistant, content: "Good: contracts now go to Legal.")]
        let chat = NSSize(width: 860, height: 900)
        for (name, bot) in [(names[15], jarvis), (names[16], boppy)] {
            store.selectedBot = bot; store.openHerdrHelper = nil
            write(name, await png(AnyView(ChatView(bot: bot).frame(width: chat.width, height: chat.height)), store, chat))
        }
        write(names[17], await png(AnyView(Form { BotEditorAdvancedSection(bot: boppy, fields: .constant(BotEditorFields(bot: boppy))) }.formStyle(.grouped)
            .frame(width: editor.width, height: editor.height).background(AppColor.panel)), store, editor))

        // What a bot runs on, by the server's names: no choice of its own, an agent running on another model than the next one would.
        store.bots = [jarvis, boppy, infra]
        let running = try? JSONDecoder().decode(HerdrClient.Agent.self, from: Data(#"{"address":"t9","createdMs":77,"name":"jarvis","state":"live","template":"starter-one","status":null}"#.utf8))
        let launched = HerdrClient.Profile(id: 1, runtimeName: "jarvis", sessions: [.init(address: "t9", createdMs: 77, runtime: .init(harness: "Claude Code", provider: nil, model: "server-model-c", modelId: "server-model-c"))])
        let models = offered["starter-one"] ?? []
        store.herdrAgentReadings[jarvis.id] = HerdrAgentReading(templates: programs, ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: models, agent: running, profiles: [launched])
        store.herdrAgentReadings[boppy.id] = HerdrAgentReading(templates: programs, ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: models)
        let tab = NSSize(width: 360, height: 420)
        write(names[18], await png(AnyView(VStack(alignment: .leading, spacing: 12) { HerdrAgentControls(bot: jarvis, templates: programs, models: models) }.padding(14)
            .frame(width: tab.width, height: tab.height, alignment: .top).background(AppColor.panel)), store, tab))
        store.selectedBot = boppy; store.infoTab = .overview
        write(names[19], await png(AnyView(InfoPanel(bot: boppy)), store, NSSize(width: 360, height: 620)))
        let listless = [HerdrClient.Template(name: "starter-three", description: nil, error: nil, runtime: .init(harness: "Another agent", provider: nil, model: nil))]
        write(names[20], await png(AnyView(VStack(alignment: .leading, spacing: 12) { HerdrAgentControls(bot: boppy, templates: listless) }.padding(14)
            .frame(width: tab.width, height: 300, alignment: .top).background(AppColor.panel)), store, NSSize(width: tab.width, height: 300)))
        // The chat header names the model beside the bot.
        store.selectedBot = jarvis
        write(names[21], await png(AnyView(ChatView(bot: jarvis).frame(width: chat.width, height: 420)), store, NSSize(width: chat.width, height: 420)))
    }
}

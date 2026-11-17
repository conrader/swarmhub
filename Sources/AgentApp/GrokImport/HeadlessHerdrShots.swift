import AppKit
import SwiftUI

/// Herdr shots of `--render-setup` (alone with `--only herdr`): every step of the setup wizard (where bots run; Connect
/// for this Mac with nothing running and connected, over SSH, by address, and each way it can fail; the main bot, new
/// and kept; the optional bots; the chat it ends in), then Settings → Servers and keys with two servers, the simple page,
/// a main bot's and another bot's Advanced settings, a bot's request to create bots waiting above the composer, and
/// a bot's helper agents: under it in the sidebar, in its Details panel, one of them opened, a server's helper settings,
/// a request for a bot passed between a bot and the main bot: both chats, and the settings of a bot that is not the main bot,
/// and what a bot runs on by name: its Model tab, its Overview, and an agent program for which the server lists no models.
/// All synthetic and in memory: Test results are built here, no server has a token, nothing connects.
@MainActor enum HeadlessHerdrShots {
    /// The wizard, step by step.
    static let wizard = ["herdr-w1-where", "herdr-w1-where-ssh", "herdr-w2-this-mac-testing", "herdr-w2-this-mac-nothing", "herdr-w2-this-mac-connected", "herdr-w2-ssh",
                         "herdr-w2-ssh-refused", "herdr-w2-ssh-no-service", "herdr-w2-address", "herdr-w2-address-wrong-key", "herdr-w2-address-unreachable",
                         "herdr-w2-no-core", "herdr-w2-no-programs", "herdr-w3-main-bot", "herdr-w3-main-bot-reading", "herdr-w3-main-bot-keep", "herdr-w3-main-bot-name-taken",
                         "herdr-w3-main-bot-one-program", "herdr-w4-more-bots", "herdr-w4-more-bots-ticked", "herdr-w5-chat"]
    static let other = ["herdr-settings-servers", "herdr-settings-simple", "herdr-editor-advanced", "herdr-editor-second-bot", "herdr-bot-request",
                        "herdr-helpers-sidebar", "herdr-helpers-details", "herdr-helper-view", "herdr-helper-settings", "herdr-main-chat", "herdr-asker-chat", "herdr-editor-not-main", "herdr-model-tab", "herdr-model-overview", "herdr-model-no-list", "herdr-model-header",
                        "herdr-editor", "herdr-editor-new", "herdr-settings-add"]
    /// A server's skill library: the list, a search, skillshare missing, a sync that failed after a switch, the
    /// confirmation before sharing with another agent program, and the same library in a bot's Details.
    static let skills = ["herdr-skills-list", "herdr-skills-search", "herdr-skills-problem", "herdr-skills-sync-failed", "herdr-skills-share-confirm", "herdr-skills-details"]
    /// Project servers: the wizard's optional step (the Herdr server's key and the address; the fingerprint of a host
    /// it has not seen; the server added; a first project; projects chosen for the main bot), the Projects part of
    /// Settings with nothing added and with a server and projects, and a bot's choice of projects in its Details.
    static let projects = ["herdr-w5-projects-key", "herdr-w5-projects-trust", "herdr-w5-projects-added", "herdr-w5-projects-first", "herdr-w5-projects-chosen",
                           "herdr-projects-settings-empty", "herdr-projects-settings", "herdr-projects-details"]
    /// What a chat says while its turn waits: the agent program starting, the agent working, a tool step running, the
    /// agent waiting for the person in its terminal; and the header of a bot whose agent is ready, or starting ahead
    /// of the first message.
    static let statuses = ["herdr-status-starting", "herdr-status-working", "herdr-status-step", "herdr-status-waiting", "herdr-status-ready", "herdr-status-warming"]
    static let names = wizard + other + skills + projects + statuses

    /// The states of a server's project servers, in the order of `projects`. Everything is made up: the key, the
    /// addresses and the fingerprints belong to no machine.
    @MainActor static func projectModels() -> [HerdrProjectsModel] {
        let keys = HerdrSSHKeys(keys: [.init(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOfTheHerdrServerNotARealOne0000000 herdr@studio", type: "ssh-ed25519", fingerprint: "SHA256:exampleExampleExampleExampleExampleExample0", comment: "herdr@studio", file: "/home/deploy/.ssh/id_ed25519.pub")],
                                canCreate: false, whereToPaste: "On the project server, add this line to ~/.ssh/authorized_keys of the account the Herdr server logs in as.", problem: nil)
        let installs = "Adding a server copies Herdr's helper program (herdr-core) to ~/.local/bin of that account there when it is missing or too old, and starts it. Nothing else is installed."
        let none = HerdrMachines(machines: [], canAdd: true, problem: nil, adding: installs)
        let box = HerdrMachine(name: "web-1", target: "deploy@10.0.0.7", host: "web-1", version: "hc 0.1.21", projects: ["shop", "docs"])
        let quiet = HerdrMachine(name: "lab", target: "deploy@10.0.0.9", state: "needs_login", reachable: false,
                                 warnings: ["lab refuses the Herdr server's SSH key. Add the Herdr server's public key to ~/.ssh/authorized_keys of that account on lab, then connect again. Herdr also tries again by itself, at first after 2 minutes."])
        let one = HerdrMachines(machines: [HerdrMachine(name: "web-1", target: "deploy@10.0.0.7", host: "web-1", version: "hc 0.1.21")], canAdd: true, problem: nil, adding: installs)
        let two = HerdrMachines(machines: [box, quiet], canAdd: true, problem: nil, adding: installs)
        let listed = [HerdrProject(id: 1, name: "shop", machine: "web-1", folder: "/srv/shop", note: "The web shop. Staging only.", machineState: "connected", reachable: true),
                      HerdrProject(id: 2, name: "docs", machine: "web-1", folder: "/srv/docs", machineState: "connected", reachable: true)]
        let question = HerdrRefusal(status: 409, kind: "unknown_host_key",
                                    message: "The Herdr server has not connected to this server before, so it does not know its host key. Compare a fingerprint below with the server's own (on the server: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). If it matches, add deploy@10.0.0.7 again with accept_host_key set to it.",
                                    host: "10.0.0.7", hostKeys: [.init(type: "ssh-ed25519", fingerprint: "SHA256:exampleFingerprintOfTheProjectServerNotReal00")])
        let added = HerdrProjectsModel.Adding.done(message: "Added web-1. Herdr's helper program (hc 0.1.21) was copied to ~/.local/bin on it and started.",
                                                   warnings: ["Programs started on web-1 stop when the last login there ends. To keep them running, run this on web-1 once: sudo loginctl enable-linger -- deploy"])
        return [HerdrProjectsModel(showing: none, keys: keys, target: "deploy@10.0.0.7", name: "web-1"),
                HerdrProjectsModel(showing: none, keys: keys, adding: .trust(question), target: "deploy@10.0.0.7", name: "web-1"),
                HerdrProjectsModel(showing: one, keys: keys, adding: added),
                HerdrProjectsModel(showing: one, keys: keys, draft: .init(name: "shop", machine: "web-1", folder: "/srv/shop", note: "The web shop. Staging only.")),
                HerdrProjectsModel(showing: HerdrMachines(machines: [box], canAdd: true, problem: nil, adding: installs), keys: keys, projects: listed),
                HerdrProjectsModel(showing: none, keys: keys),
                HerdrProjectsModel(showing: two, keys: keys, projects: listed),
                HerdrProjectsModel(showing: two, keys: keys, projects: listed)]
    }

    /// A library as a server would report it: twelve skills, two of them off, shared with two agent programs.
    static let library: HerdrSkillLibrary = {
        let named: [(String, String?)] = [("brand", "Brand voice, visual identity and messaging: what to say and how it should look."), ("changelog", "Write release notes from the commits since the last tag."),
            ("code-review", "Review a diff for correctness bugs before it is merged."), ("csv-cleanup", "Fix malformed rows, misplaced headers and mixed encodings in a CSV file."),
            ("design-review", "Judge a screen as a design: alignment, wording, what a first-time user sees."), ("incident-notes", nil), ("meeting-minutes", "Turn a transcript into decisions, owners and dates."),
            ("pdf-forms", "Fill, merge and split PDF files."), ("release-checklist", "Walk a release through its checks and say what is missing."), ("sql-explain", "Read a query plan and say where the time goes."),
            ("test-triage", "Sort failing tests into broken code, broken test and flaky."), ("writing-plainly", "Short sentences, concrete words, no filler.")]
        let skills = named.enumerated().map { index, skill in HerdrSkillLibrary.Skill(name: skill.0, path: skill.0, description: skill.1, enabled: index != 3 && index != 9, origin: "local") }
        return HerdrSkillLibrary(installed: true, version: "1.0", source: "/home/deploy/.config/skillshare/skills", skillCount: skills.count, skills: skills,
                                 targets: [.init(name: "codex", linked: 10, skillsEnabled: true), .init(name: "universal", linked: 10, skillsEnabled: true)])
    }()

    /// The Skills section's states as presets, in the order of `skills` (the last is shown in a bot's Details).
    @MainActor static func skillModels() -> [HerdrSkillsModel] {
        let missing = HerdrSkillLibrary(installed: false, problem: "skillshare is not installed on this server. Install it, or set SWARMHUB_SKILLSHARE to its full path.")
        let failed = HerdrSkillsCopy.notSynced(HerdrSkillsCopy.changedInLibrary(["csv-cleanup"], on: false), reason: "skillshare took too long and was stopped.")
        return [HerdrSkillsModel(showing: library, note: "sql-explain is off. " + HerdrSkillsCopy.synced("codex (10 skills) and universal (10 skills)")),
                HerdrSkillsModel(showing: library, query: "review"), HerdrSkillsModel(showing: missing), HerdrSkillsModel(showing: library, behind: .failed(failed)),
                HerdrSkillsModel(showing: library, sharing: .offered(["claude"]), confirming: "claude"), HerdrSkillsModel(showing: library, behind: .waiting)]
    }

    /// What a server offers in the shots: two agent programs under the server's names, the first with three models.
    static let offer = HerdrOffer(programs: [HerdrProgram(template: "starter-one", name: "Claude Code", takesModel: true, models: [.init(id: "server-model-a", label: "Server model A"), .init(id: "server-model-b", label: "Server model B"), .init(id: "server-model-c", label: "Server model C")]),
                                             HerdrProgram(template: "starter-two", name: "Codex", takesModel: true, models: [.init(id: "server-model-d", label: "Server model D")])])

    /// The wizard's screens as presets: each is a state the window can be in, built without a server.
    static func wizardFlows(server: HerdrServer, thisMac: HerdrServer) -> [SetupFlow] {
        var whereSSH = SetupFlow(); whereSSH.place = .ssh
        var local = SetupFlow(); local.apply(.pickHerdr(.local))
        var nothing = local; nothing.apply(.herdrTest(.nothingHere(port: HerdrServer.defaultPort)))
        var localConnected = local; localConnected.apply(.herdrTest(.connected(server: thisMac, key: nil, offer: offer)))
        var ssh = SetupFlow(); ssh.place = .ssh; ssh.apply(.pickHerdr(.ssh)); ssh.herdr.sshHost = "studio.example.com"; ssh.herdr.sshUser = "deploy"; ssh.herdr.sshKeyPath = "~/.ssh/id_ed25519"
        var refused = ssh; refused.apply(.herdrTest(.failed(HerdrSetupProblem.sshFailed("deploy@studio.example.com: Permission denied (publickey).").line(for: server))))
        var noService = ssh; noService.apply(.herdrTest(.failed(HerdrSetupProblem.sshNoService.line(for: server))))
        var address = SetupFlow(); address.place = .address; address.apply(.pickHerdr(.address)); address.herdr.address = "http://127.0.0.1:8787"; address.herdr.key = "synthetic"
        let typed = HerdrServer(id: "typed", name: "127.0.0.1", kind: .address, address: "http://127.0.0.1:8787")
        var wrongKey = address; wrongKey.apply(.herdrTest(.failed(HerdrSetupProblem.wrongKey.line(for: typed))))
        var unreachable = address; unreachable.apply(.herdrTest(.failed(HerdrSetupProblem.unreachable.line(for: typed))))
        var noCore = address; noCore.apply(.herdrTest(.failed(HerdrSetupProblem.noCore.line(for: typed))))
        var noPrograms = address; noPrograms.apply(.herdrTest(.connected(server: typed, key: "synthetic", offer: HerdrOffer())))
        var connected = ssh; connected.apply(.herdrTest(.connected(server: server, key: nil, offer: offer)))
        var mainBot = connected; mainBot.apply(.advance)
        let existing = [HerdrSetupBot(id: UUID(), name: "Jarvis", isMain: true, template: "starter-one"), HerdrSetupBot(id: UUID(), name: "Research", isMain: false, template: "starter-one")]
        var keep = ssh; keep.apply(.herdrTest(.connected(server: server, key: nil, offer: offer), bots: existing)); keep.apply(.advance)
        var taken = keep; taken.mainBot.keep = nil; taken.mainBot.name = "Research"
        var oneProgram = ssh; oneProgram.apply(.herdrTest(.connected(server: server, key: nil, offer: HerdrOffer(programs: [offer.programs[1]])))); oneProgram.apply(.advance)
        var more = mainBot; more.mainBot.instructions = "You run my projects and keep me posted."; more.apply(.advance)
        var ticked = more; ticked.moreBots = ["starter-two"]
        return [SetupFlow(), whereSSH, local, nothing, localConnected, ssh, refused, noService, address, wrongKey, unreachable, noCore, noPrograms,
                mainBot, SetupFlow(saved: server), keep, taken, oneProgram, more, ticked]
    }

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let server = HerdrServer(id: "box1", name: "Studio server", kind: .ssh, address: HerdrServer.loopback(port: HerdrServer.defaultPort), sshHost: "studio.example.com", sshUser: "deploy")

        for (name, flow) in zip(wizard, wizardFlows(server: server, thisMac: store.herdrServers[0])) {
            write(name, await png(AnyView(SetupView(preset: flow, presetTesting: name.hasSuffix("-testing"))), store, HeadlessSetup.size))
        }
        // The chat the wizard ends in: the main bot, nothing said yet, and the line about its first reply.
        do {
            let landing = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); landing.isSetupPreview = false
            var flow = wizardFlows(server: server, thisMac: landing.herdrServers[0])[19]; flow.mainBot.instructions = ""
            let size = NSSize(width: 860, height: 420)
            if let main = try? landing.commitSetupWizard(server: flow.herdrServer, key: nil, main: flow.mainBot, more: flow.moreChosen, offer: flow.herdrOffer) {
                write(wizard[20], await png(AnyView(ChatView(bot: main).frame(width: size.width, height: size.height)), landing, size))
            } else { write(wizard[20], nil) }
        }

        store.saveHerdrServer(store.herdrServers[0], token: nil); store.saveHerdrServer(server, token: nil)
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", persona: "You run the team.", backend: .herdr); jarvis.canManageBots = true
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .herdr)
        store.bots = [jarvis, infra]; store.setHerdrServer(server.id, for: jarvis)
        // Settings → Servers and keys beside its pane list is this wide.
        let settings = NSSize(width: 570, height: 640)
        func pane<V: View>(_ view: V, _ size: NSSize) -> AnyView {
            AnyView(ScrollView { view.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading) }.frame(width: size.width, height: size.height).background(AppColor.panel))
        }
        write(other[0], await png(pane(SettingsAccountPane(), settings), store, settings))
        let adding = NSSize(width: 570, height: 900)
        write(other[18], await png(pane(HerdrSettingsSection(chosen: "+"), adding), store, adding))
        write(other[1], await png(AnyView(SettingsSimplePane(openAdvanced: {})), store, HeadlessSetup.settingsSize))
        let editor = NSSize(width: 560, height: 1_500)
        func advanced(_ bot: Bot) -> AnyView {
            AnyView(BotEditorAdvancedSection(bot: bot, fields: .constant(BotEditorFields(bot: bot))).padding(.horizontal, 32).padding(.vertical, 24)
                .frame(width: editor.width, height: editor.height, alignment: .top).background(AppColor.panel))
        }
        for (name, bot) in [(other[2], jarvis), (other[3], infra)] { write(name, await png(advanced(bot), store, editor)) }
        // A bot's settings as the sheet shows them, and the sheet for a new bot.
        let sheet = NSSize(width: 560, height: 720)
        write(other[16], await png(AnyView(BotEditorView(bot: jarvis)), store, sheet))
        write(other[17], await png(AnyView(BotEditorView(bot: nil)), store, sheet))
        let block = "```swarmhub\n[{\"op\":\"create_bot\",\"name\":\"Research\",\"instructions\":\"You find and check sources, and answer with links.\",\"avatar\":{\"shape\":\"star\",\"colour\":\"blue\"}},{\"op\":\"create_bot\",\"name\":\"Writer\",\"instructions\":\"You turn notes into clear drafts.\",\"runtime\":\"Codex\"}]\n```"
        jarvis.messages = [ChatMessage(role: .user, content: "Create two bots: one for research and one for writing."), ChatMessage(role: .assistant, content: "I proposed Research and Writer.\n\n" + block)]
        let card = NSSize(width: 760, height: 220)
        write(other[4], await png(AnyView(HerdrBotRequestCard(manager: jarvis).frame(width: card.width, height: card.height).background(AppColor.chat)), store, card))

        // Helpers as the server would list them: one working, one answered, one stopped at a prompt. The model is whatever the server said.
        let helpers = [HerdrClient.Helper(address: "t43", createdMs: 3, name: "tests", model: "server-model-b", difficulty: "medium", task: "Add tests for the CSV importer's quoted fields and make them pass.", state: "live", status: .init(state: "working"), answered: false),
                       HerdrClient.Helper(address: "t42", createdMs: 2, name: "rename", model: "server-model-a", difficulty: "easy", task: "Rename `fetchAll` to `loadAll` everywhere in Sources/.", state: "live", status: .init(state: "done"), answered: true,
                                          reply: .init(id: 9, text: "Renamed 14 call sites in 6 files; the build passes.")),
                       HerdrClient.Helper(address: "t41", createdMs: 1, name: "design", model: "server-model-c", difficulty: "hard", task: "Propose how the importer should report partial failures.", state: "live", status: .init(state: "blocked"), answered: false)]
        store.herdrHelpers[jarvis.id] = HerdrClient.Helpers(core: "core", parent: .init(address: "t40", createdMs: 0), limit: 3, stopAfterSeconds: 60, helpers: helpers)
        store.bots = [jarvis, Bot(name: "Research", title: "Sources and links", backend: .herdr), infra]
        let sidebar = NSSize(width: SidebarMetrics.width.ideal, height: 460)
        write(other[5], await png(AnyView(SidebarView(selection: .constant(jarvis)).frame(width: sidebar.width, height: sidebar.height)), store, sidebar))
        store.selectedBot = jarvis; store.infoTab = .overview
        write(other[6], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 1_040)))
        let log = HerdrClient.HelperLog(tools: [.init(seq: 1, tool: "Grep", detail: "fetchAll", finished: true, failed: false), .init(seq: 2, tool: "Edit", detail: "Sources/Importer/CSVReader.swift", finished: true, failed: false),
                                                .init(seq: 3, tool: "Bash", detail: "swift build", finished: true, failed: false)],
                                        screen: "● Renamed 14 call sites in 6 files; the build passes.\n\n✻ Worked for 41s\n────────────────────────────────────────\n❯ ")
        var shownLog = log; shownLog.replies = [.init(id: 9, kind: "reply", text: "Renamed **14 call sites** in 6 files; the build passes.\n\n- `CSVReader.swift`\n- `ImportQueue.swift`")]
        let opened = NSSize(width: 760, height: 720), choice = HerdrHelperSelection(botID: jarvis.id, helperID: helpers[1].id)
        store.openHerdrHelper = choice
        write(other[7], await png(AnyView(HerdrHelperView(bot: jarvis, selection: choice, helper: helpers[1], core: "core", log: shownLog).frame(width: opened.width, height: opened.height)), store, opened))
        // A server's helper settings as read: two agent programs, the models each lists, hard tasks not allowed yet.
        let programs = [HerdrClient.Template(name: "starter-one", description: nil, error: nil, runtime: .init(harness: "Claude Code", provider: nil, model: nil), modelAgent: "one"),
                        HerdrClient.Template(name: "starter-two", description: nil, error: nil, runtime: .init(harness: "Codex", provider: nil, model: nil), modelAgent: "two")]
        let offered: [String: [HerdrClient.Template.Model]] = ["starter-one": [.init(id: "server-model-a", label: "Server model A"), .init(id: "server-model-c", label: "Server model C")],
                                                              "starter-two": [.init(id: "server-model-b", label: "Server model B")]]
        let policy = HerdrHelperPolicy(maxRunning: 3, stopAfterSeconds: 60, stopUnansweredAfterSeconds: 1_800, difficulties: ["easy": .init(template: "starter-one", model: "server-model-a"), "medium": .init(template: "starter-two", model: "server-model-b")])
        let read = HerdrHelperPolicySection.Loaded(settings: .init(policy: policy, problem: nil, bounds: .init(maxRunning: .init(min: 0, max: 16), stopAfterSeconds: .init(min: 5, max: 86_400, default: 60), stopUnansweredAfterSeconds: .init(min: 60, max: 604_800, default: 1_800))), templates: programs, models: offered)
        let policySize = NSSize(width: 570, height: 1_120)
        write(other[8], await png(pane(HerdrHelperPolicySection(server: server, named: true, preset: read), policySize), store, policySize))

        // A bot asks the main bot for a bot. Jarvis created one on its own decision (Remove, Keep) and left another to the person.
        let boppy = Bot(name: "Boppy", title: "Product", persona: "You look after the product.", backend: .herdr)
        let legal = Bot(name: "Legal", title: "Created by Jarvis", persona: "You review the contracts people send to the company and say what to change.", backend: .herdr)
        store.bots = [jarvis, boppy, legal, infra]
        for bot in [boppy, legal] { store.setHerdrServer(server.id, for: bot) }
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
        for (name, bot) in [(other[9], jarvis), (other[10], boppy)] {
            store.selectedBot = bot; store.openHerdrHelper = nil
            write(name, await png(AnyView(ChatView(bot: bot).frame(width: chat.width, height: chat.height)), store, chat))
        }
        write(other[11], await png(advanced(boppy), store, editor))

        // What a bot runs on, by the server's names: no choice of its own, an agent running on another model than the next one would.
        store.bots = [jarvis, boppy, infra]
        let running = try? JSONDecoder().decode(HerdrClient.Agent.self, from: Data(#"{"address":"t9","createdMs":77,"name":"jarvis","state":"live","template":"starter-one","status":null}"#.utf8))
        let launched = HerdrClient.Profile(id: 1, runtimeName: "jarvis", sessions: [.init(address: "t9", createdMs: 77, runtime: .init(harness: "Claude Code", provider: nil, model: "server-model-c", modelId: "server-model-c"))])
        let models = offered["starter-one"] ?? []
        store.herdrAgentReadings[jarvis.id] = HerdrAgentReading(templates: programs, ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: models, agent: running, profiles: [launched])
        store.herdrAgentReadings[boppy.id] = HerdrAgentReading(templates: programs, ownTemplate: nil, sharedTemplate: nil, ownModel: nil, offered: models)
        let tab = NSSize(width: 360, height: 700)
        write(other[12], await png(AnyView(VStack(alignment: .leading, spacing: 12) { HerdrAgentControls(bot: jarvis, templates: programs, models: models) }.padding(14)
            .frame(width: tab.width, height: tab.height, alignment: .top).background(AppColor.panel)), store, tab))
        store.selectedBot = boppy; store.infoTab = .overview
        write(other[13], await png(AnyView(InfoPanel(bot: boppy)), store, NSSize(width: 360, height: 720)))
        let listless = [HerdrClient.Template(name: "starter-three", description: nil, error: nil, runtime: .init(harness: "Another agent", provider: nil, model: nil))]
        write(other[14], await png(AnyView(VStack(alignment: .leading, spacing: 12) { HerdrAgentControls(bot: boppy, templates: listless) }.padding(14)
            .frame(width: tab.width, height: 520, alignment: .top).background(AppColor.panel)), store, NSSize(width: tab.width, height: 520)))
        // The server's skill library in Settings, state by state, and in a bot's Details.
        let skillStates = skillModels(), skillsSize = NSSize(width: 570, height: 1_180)
        for (name, model) in zip(skills.dropLast(), skillStates) {
            write(name, await png(pane(HerdrSkillsSection(server: server, named: true, preset: model), skillsSize), store, skillsSize))
        }
        let panel = NSSize(width: 360, height: 900)
        write(skills[5], await png(AnyView(ScrollView { HerdrSkillsPanel(bot: jarvis, preset: skillStates[5]).padding(14) }.frame(width: panel.width, height: panel.height).background(AppColor.panel)), store, panel))

        // Project servers: the wizard's last step state by state, the Projects part of Settings, and a bot's Details.
        do {
            let states = projectModels()
            var offering = offer; offering.projectServers = true
            var flow = SetupFlow(); flow.place = .ssh; flow.apply(.pickHerdr(.ssh)); flow.herdr.sshHost = "studio.example.com"; flow.herdr.sshUser = "deploy"
            flow.apply(.herdrTest(.connected(server: server, key: nil, offer: offering))); flow.apply(.advance); flow.apply(.advance); flow.apply(.advance)
            for index in 0..<5 {
                var shown = flow
                if index == 4 { shown.mainProjects = [HerdrBotProject(id: 1, name: "shop", machine: "web-1")] }
                let size = NSSize(width: HeadlessSetup.size.width, height: index == 0 || index == 3 ? 860 : index == 4 ? 780 : HeadlessSetup.size.height)
                write(projects[index], await png(AnyView(SetupView(preset: shown, presetProjects: states[index], presetHeight: size.height)), store, size))
            }
            let partSize = NSSize(width: 570, height: 1_180)
            write(projects[5], await png(pane(HerdrProjectsSection(server: server, named: true, preset: states[5]), NSSize(width: 570, height: 760)), store, NSSize(width: 570, height: 760)))
            write(projects[6], await png(pane(HerdrProjectsSection(server: server, named: true, preset: states[6]), partSize), store, partSize))
            store.setHerdrProjects([HerdrBotProject(id: 1, name: "shop", machine: "web-1")], for: boppy)
            let details = NSSize(width: 360, height: 620)
            write(projects[7], await png(AnyView(ScrollView { HerdrBotProjectsSection(bot: boppy, preset: states[7]).padding(14) }.frame(width: details.width, height: details.height).background(AppColor.panel)), store, details))
        }

        // The chat header names the model beside the bot.
        store.selectedBot = jarvis
        write(other[15], await png(AnyView(ChatView(bot: jarvis).frame(width: chat.width, height: 420)), store, NSSize(width: chat.width, height: 420)))

        // What the chat says while a turn waits, state by state, and the header of a bot whose agent is ready or starting.
        let program = store.herdrProgramName(for: boppy), small = NSSize(width: chat.width, height: 300)
        var step = ToolActivity()
        step.apply(ToolEvent(phase: .started, name: "read_file", preview: "Sources/Importer/CSVReader.swift", callID: "1"), at: .now - 60); step.apply(ToolEvent(phase: .completed, name: "read_file", callID: "1"), at: .now - 58)
        step.apply(ToolEvent(phase: .started, name: "bash", preview: "swift test --filter CSVReaderTests", callID: "2"), at: .now - 40)
        let waiting: [(status: HerdrTurnStatus, seconds: TimeInterval, activity: ToolActivity?)] =
            [(.starting(program: program), 42, nil), (.working(program: program), 8, nil), (.working(program: program), 72, step), (.blocked(program: program), 125, step)]
        for (name, state) in zip(statuses, waiting) {
            let reply = ChatMessage(role: .assistant, content: "", createdAt: .now - state.seconds, isStreaming: true, metadata: [TurnKey.agent: state.status.code], turnState: .incomplete)
            reply.activity = state.activity
            boppy.messages = [ChatMessage(role: .user, content: "hi", createdAt: .now - state.seconds), reply]
            store.selectedBot = boppy
            write(name, await png(AnyView(ChatView(bot: boppy).frame(width: small.width, height: small.height)), store, small))
        }
        boppy.messages = [ChatMessage(role: .user, content: "hi"), ChatMessage(role: .assistant, content: "Hi! What would you like to work on?")]
        for (name, readiness) in [(statuses[4], HerdrAgentReadiness.ready), (statuses[5], .starting(program: program))] {
            store.herdrReadiness[boppy.id] = readiness
            write(name, await png(AnyView(ChatView(bot: boppy).frame(width: small.width, height: small.height)), store, small))
        }
        store.herdrReadiness[boppy.id] = nil
    }
}

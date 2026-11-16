import SwiftUI

/// Settings → Advanced → Servers and keys: the Herdr servers. Each has its access token (Keychain), a Test, starter
/// bots and Remove; below them a new server is added the same three ways the setup window offers, and a ready-made
/// server is only announced. The template new bots start from applies to every server.
struct HerdrSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(HerdrBackend.templateKey) private var template = ""
    @AppStorage(LegacySurface.key) private var legacy = false
    @State private var templates: [HerdrClient.Template] = []
    @State private var draft = HerdrServerDraft(kind: .ssh); @State private var adding = false; @State private var addResult = ""
    @State private var moveResult = ""

    var body: some View {
        let servers = store.herdrServers
        ForEach(servers) { server in
            HerdrServerSection(server: server, canRemove: servers.count > 1) { templates = $0 }
        }
        Section("Add a Herdr server") {
            Picker("Where it runs", selection: $draft.kind) {
                Text(SetupCopy.herdrLocalTitle).tag(HerdrServer.Kind.local)
                Text(SetupCopy.herdrSSHTitle).tag(HerdrServer.Kind.ssh)
                Text(SetupCopy.herdrAddressTitle).tag(HerdrServer.Kind.address)
            }
            HerdrServerFields(draft: $draft, submit: add)
            HStack {
                Button("Test and add", action: add).disabled(adding || draft.problem != nil)
                if adding { ProgressView().controlSize(.small) }
                Text(addResult.isEmpty ? draft.problem ?? "" : addResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent(SetupCopy.herdrReadyMadeTitle) { Button(ManagedHosting.badge) {}.disabled(true) }
            Text(SetupCopy.herdrReadyMadeDetail + " Nothing can be ordered here.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Herdr bots") {
            HerdrTemplatePicker(title: "Agent runtime for new bots", automatic: "First available", selection: $template, templates: templates)
            let movable = store.botsMovableToHerdr
            if !movable.isEmpty {
                HStack {
                    Button(movable.count == 1 ? "Move the 1 Hermes or OpenClaw bot to Herdr" : "Move all \(movable.count) Hermes and OpenClaw bots to Herdr") {
                        moveResult = "Moved \(store.moveAllToHerdr()) to \(servers[0].name). Each starts its Herdr agent with its next message."
                    }
                    Text(moveResult).font(.caption).foregroundStyle(.secondary)
                }
                Text("A moved bot keeps its name, avatar, instructions and chat history and runs on \(servers[0].name) from then on. What lived on its old server (memory, skills, routines, connected apps) does not move.").font(.caption).foregroundStyle(.secondary)
            } else if !moveResult.isEmpty { Text(moveResult).font(.caption).foregroundStyle(.secondary) }
            Toggle("Show Hermes and OpenClaw settings", isOn: $legacy)
            Text("\(AppConstants.name) is moving to Herdr. The older servers' settings, their setup steps and the Backend picker stay hidden unless this is on.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        guard draft.problem == nil, !adding else { return }
        let draft = draft
        adding = true; addResult = ""
        Task {
            switch await store.testSetupHerdr(draft) {
            case .connected(let server, let key, _):
                store.saveHerdrServer(server, token: key)
                addResult = "Added \(server.name)."; self.draft = HerdrServerDraft(kind: draft.kind)
            case .nothingHere(let port): addResult = SetupCopy.herdrNothingHere(port: port) + " " + SetupCopy.herdrStartHelp + " " + SetupHerdrStep.startCommand
            case .failed(let line): addResult = line
            }
            adding = false
        }
    }
}

/// One saved server: where it is, its token, Test, starter bots and Remove.
struct HerdrServerSection: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer; let canRemove: Bool
    /// Hands the templates a passed Test read to the picker below the list.
    let loaded: ([HerdrClient.Template]) -> Void
    @State private var name = ""; @State private var token = ""; @State private var result = ""; @State private var working = false
    @State private var confirmRemove = false

    var body: some View {
        Section("Herdr server") {
            TextField("Name", text: $name).onSubmit(rename)
            LabeledContent("Where") { Text(server.place).foregroundStyle(.secondary).textSelection(.enabled) }
            SecureField("Access token", text: $token, prompt: Text(tokenPrompt)).onChange(of: token) { _, value in
                let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if typed != store.keyStore.key(for: server.keyAccount) { store.setHerdrToken(typed, for: server) }
            }
            HStack {
                Button("Test") { test() }.disabled(working)
                Button("Add starter bots") { addStarters() }.disabled(working).help("Adds one bot for each agent program this server has, on the model the server lists first.")
                if canRemove { Button("Remove…", role: .destructive) { confirmRemove = true }.disabled(working) }
                if working { ProgressView().controlSize(.small) }
            }
            if !result.isEmpty { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { name = server.name; token = store.keyStore.key(for: server.keyAccount) }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeHerdrServer(server) }
        } message: { Text("Its \(store.herdrBots(on: server).count) bots stay and move to the first server left. Nothing on the server itself changes.") }
    }

    private var bots: Int { store.herdrBots(on: server).count }
    private var tokenPrompt: String {
        if !token.isEmpty { return "" }
        return store.herdrToken(for: server).isEmpty ? (server.kind == .ssh ? "Read from the server at Test" : "Paste it here") : "Found without typing"
    }
    private var caption: String {
        let count = "\(bots == 1 ? "1 bot runs" : "\(bots) bots run") here."
        switch server.kind {
        case .local: return "Herdr on this Mac. \(count)"
        case .ssh: return "\(AppConstants.name) opens the SSH connection itself and reopens it when it drops (the same port on both ends, because Herdr checks it). \(count)"
        case .address: return "Herdr answers on its own machine's 127.0.0.1 only: this address must be that port forwarded to this Mac, with the same number. \(count)"
        }
    }

    private func rename() {
        var changed = server; changed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !changed.name.isEmpty, changed != server { store.saveHerdrServer(changed, token: nil) }
    }

    private func test() {
        rename(); working = true; result = ""
        Task {
            do {
                let tested = try await store.testHerdrServer(server)
                if let found = tested.token { store.setHerdrToken(found, for: server); token = found }
                result = tested.line
                loaded(try await store.herdrTemplates(on: server))
            } catch { result = error.localizedDescription }
            working = false
        }
    }

    private func addStarters() {
        working = true; result = ""
        Task {
            do {
                let added = try await store.addHerdrStarterBots(on: server)
                result = added.isEmpty ? "This server's agent programs already have a bot each." : "Added \(added.joined(separator: " and ")). Find them in the sidebar."
            } catch { result = error.localizedDescription }
            working = false
        }
    }
}

/// A Herdr bot's agent in its editor's Advanced part: the same controls as the Details panel's Model tab.
struct HerdrBotSection: View {
    @ObservedObject var bot: Bot
    var body: some View { Section("Herdr agent") { HerdrAgentControls(bot: bot) } }
}

/// Which agent program and model a Herdr bot runs, and a way to start it afresh. Both choices are used when the bot
/// next starts an agent; a running agent keeps what it started with until "Start a fresh agent".
struct HerdrAgentControls: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var template = ""; @State private var model = ""
    @State private var templates: [HerdrClient.Template] = []; @State private var models: [HerdrClient.Template.Model] = []
    @State private var note = ""; @State private var loaded = false; @State private var restarting = false; @State private var steers = true
    @State private var serverID = ""

    /// The template this bot would start from now: its own, else the one for new bots, else the first available.
    private var effective: HerdrClient.Template? {
        let wanted = template.isEmpty ? store.defaults.string(forKey: HerdrBackend.templateKey) ?? "" : template
        return templates.first { $0.name == wanted } ?? (wanted.isEmpty ? templates.first : nil)
    }

    var body: some View {
        let servers = store.herdrServers
        if servers.count > 1 {
            // Another server has its own agent programs and models, so both choices start over there.
            Picker("Server", selection: $serverID) { ForEach(servers) { Text($0.name).tag($0.id) } }
                .onChange(of: serverID) { _, value in
                    guard loaded, value != store.herdrServer(for: bot).id else { return }
                    store.setHerdrServer(value, for: bot); template = ""; model = ""; store.setHerdrTemplate("", for: bot); store.setHerdrModel("", for: bot)
                    Task { await loadTemplates(); await loadModels() }
                }
        }
        HerdrTemplatePicker(title: "Agent runtime", automatic: "Same as new bots", selection: $template, templates: templates)
            .onChange(of: template) { _, value in
                guard loaded else { return }
                store.setHerdrTemplate(value, for: bot); model = ""; store.setHerdrModel("", for: bot)
                Task { await loadModels() }
            }
        if effective?.takesModel != false {
            Picker("Model", selection: $model) {
                Text("Agent's default").tag("")
                ForEach(models, id: \.id) { Text($0.label ?? $0.id).tag($0.id) }
                if !model.isEmpty, !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            }
            .onChange(of: model) { _, value in if loaded { store.setHerdrModel(value, for: bot) } }
        }
        Toggle("Add messages to the running answer (steer)", isOn: Binding(get: { steers }, set: { steers = $0; store.setHerdrSteers($0, for: bot) }))
            .help("On: a message you send while the agent is answering goes straight to it. Off: the message waits until the answer ends.")
        HStack {
            Button("Start a fresh agent") { restart() }.disabled(restarting)
            if restarting { ProgressView().controlSize(.small) }
        }
        Text(note.isEmpty ? "Runtime and model apply when this bot next starts an agent. A running agent keeps its own until you start a fresh one, which also clears what the agent remembers of this chat." : note)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .task {
                template = store.defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""; model = store.herdrModel(for: bot); steers = store.herdrSteers(bot)
                serverID = store.herdrServer(for: bot).id
                await loadTemplates(); await loadModels(); loaded = true
            }
    }

    private func loadTemplates() async {
        do { templates = try await store.herdrTemplates(on: store.herdrServer(for: bot)); note = "" } catch { templates = []; note = error.localizedDescription }
    }

    private func loadModels() async {
        guard let effective, effective.takesModel else { models = []; return }
        do { models = try await store.herdrClient(for: store.herdrServer(for: bot)).models(for: effective) } catch { models = effective.models ?? [] }
    }

    private func restart() {
        restarting = true; note = ""
        Task {
            do { note = try await store.restartHerdrAgent(for: bot) ? "The running agent was closed. Your next message starts a fresh one." : "No agent is running. Your next message starts one." }
            catch { note = error.localizedDescription }
            restarting = false
        }
    }
}

/// Overview's line for a Herdr bot, where a Hermes bot shows its memory.
struct HerdrOverviewSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent").font(.headline)
            Text("Runs on \(store.herdrServer(for: bot).name) as \((try? store.herdrBackend(for: bot).agentName) ?? "an agent named after this bot"). It keeps its own memory of the chat while it runs; choose its runtime and model under Model.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The templates the bridge reported, plus the saved choice when it is not among them (not loaded yet, or removed).
struct HerdrTemplatePicker: View {
    let title: String; let automatic: String
    @Binding var selection: String
    let templates: [HerdrClient.Template]

    var body: some View {
        Picker(title, selection: $selection) {
            Text(automatic).tag("")
            ForEach(templates, id: \.name) { Text($0.label).tag($0.name) }
            if !selection.isEmpty, !templates.contains(where: { $0.name == selection }) { Text(selection).tag(selection) }
        }
    }
}

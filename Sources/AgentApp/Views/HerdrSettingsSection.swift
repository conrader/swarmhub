import SwiftUI

/// Settings → Advanced → Servers and keys: the Herdr servers. Each has its access token (Keychain), a Test, starter
/// bots and Remove, and under it the server's helper settings (`HerdrHelperPolicySection`); below them a new server is added the same three ways the setup window offers, and a ready-made
/// server is only announced. The template new bots start from applies to every server.
struct HerdrSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(HerdrBackend.templateKey) private var template = ""
    @State private var templates: [HerdrClient.Template] = []
    @State private var draft = HerdrServerDraft(kind: .ssh); @State private var adding = false; @State private var addResult = ""

    var body: some View {
        let servers = store.herdrServers
        ForEach(servers) { server in
            HerdrServerSection(server: server, canRemove: servers.count > 1) { templates = $0 }
            HerdrHelperPolicySection(server: server, named: servers.count > 1)
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
            HerdrTemplatePicker(title: "Agent runtime for new bots", automatic: templates.first.map { "\($0.label) (first available)" } ?? "First available", selection: $template, templates: templates)
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
/// next starts an agent; a running agent keeps what it started with until "Start a fresh agent". Nothing is shown as
/// a placeholder: "no choice" reads as the agent program new bots use and the first model the server offers for it
/// (which is what the bot's next agent is started on), and the running agent's own model is named beside it.
struct HerdrAgentControls: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var template = ""; @State private var model = ""
    @State private var templates: [HerdrClient.Template]; @State private var models: [HerdrClient.Template.Model]
    @State private var note = ""; @State private var loaded = false; @State private var restarting = false; @State private var steers = true
    @State private var serverID = ""
    /// The server's lists were read (a render passes them in); until then the default entries cannot be named.
    @State private var listed: Bool
    private let preset: Bool

    /// `templates` and `models` (renders and tests) show a read without making one.
    init(bot: Bot, templates: [HerdrClient.Template]? = nil, models: [HerdrClient.Template.Model] = []) {
        self.bot = bot; preset = templates != nil
        _templates = State(initialValue: templates ?? []); _models = State(initialValue: models); _listed = State(initialValue: templates != nil)
    }

    private var shared: String? { store.defaults.string(forKey: HerdrBackend.templateKey) }
    /// The template this bot would start from now: its own, else the one for new bots, else the first available.
    private var effective: HerdrClient.Template? { HerdrAgentReading.template(own: template, shared: shared, in: templates).template }

    var body: some View {
        let servers = store.herdrServers, reading = store.herdrAgentReadings[bot.id]
        if servers.count > 1 {
            // Another server has its own agent programs and models, so both choices start over there.
            Picker("Server", selection: $serverID) { ForEach(servers) { Text($0.name).tag($0.id) } }
                .onChange(of: serverID) { _, value in
                    guard loaded, value != store.herdrServer(for: bot).id else { return }
                    store.setHerdrServer(value, for: bot); template = ""; model = ""; store.setHerdrTemplate("", for: bot); store.setHerdrModel("", for: bot)
                    Task { await loadTemplates(); await loadModels(); await store.refreshHerdrAgentReading(for: bot) }
                }
        }
        HerdrTemplatePicker(title: "Agent runtime", automatic: HerdrAgentReading.defaultLabel(shared: shared, in: templates) ?? (listed ? "None this server can start" : "Reading…"),
                            selection: $template, templates: templates)
            .onChange(of: template) { _, value in
                guard loaded else { return }
                store.setHerdrTemplate(value, for: bot); model = ""; store.setHerdrModel("", for: bot)
                Task { await loadModels(); await store.refreshHerdrAgentReading(for: bot) }
            }
        if effective?.takesModel == true, !(listed && models.isEmpty) {
            Picker("Model", selection: $model) {
                // No choice of its own: the first model the server offers, which the bot's next agent is started on.
                Text(models.first.map { "\(HerdrAgentReading.name($0)) (default)" } ?? "Reading…").tag("")
                ForEach(models, id: \.id) { Text(HerdrAgentReading.name($0)).tag($0.id) }
                if !model.isEmpty, !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            }
            .onChange(of: model) { _, value in
                guard loaded else { return }
                store.setHerdrModel(value, for: bot)
                Task { await store.refreshHerdrAgentReading(for: bot) }
            }
        } else if listed, effective != nil {
            LabeledContent("Model") { Text(HerdrAgentReading.programPicks).foregroundStyle(.secondary) }
                .help("This server lists no models for this agent program, so the program starts on its own choice.")
        }
        if let running = reading?.runningLine {
            Text([running, reading?.pendingLine].compactMap { $0 }.joined(separator: " ")).font(.caption).foregroundStyle(reading?.pendingLine == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
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
                if !preset { await loadTemplates(); await loadModels(); await store.refreshHerdrAgentReading(for: bot) }
                loaded = true
            }
    }

    private func loadTemplates() async {
        do { templates = try await store.herdrTemplates(on: store.herdrServer(for: bot)); note = ""; listed = true } catch { templates = []; note = error.localizedDescription }
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
            await store.refreshHerdrAgentReading(for: bot)
            restarting = false
        }
    }
}

/// Overview's lines for a Herdr bot: where its agent runs, and on which agent
/// program and model, by the server's names for them.
struct HerdrOverviewSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent").font(.headline)
            Text("Runs on \(store.herdrServer(for: bot).name) as \((try? store.herdrBackend(for: bot).agentName) ?? "an agent named after this bot"). It keeps its own memory of the chat while it runs.\(store.createsHerdrBots(bot) ? " It is the main bot of \(store.herdrServer(for: bot).name): only it creates bots, and other bots ask it." : "")")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let reading = store.herdrAgentReadings[bot.id] {
                Text(reading.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Change either under Model.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Its agent program and model are under Model.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Only the real app reads on its own; a preview or test store shows what it was given.
        .task(id: bot.id) { if store.launchWorkEnabled { await store.refreshHerdrAgentReading(for: bot) } }
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

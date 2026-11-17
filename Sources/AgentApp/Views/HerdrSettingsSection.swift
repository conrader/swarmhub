import SwiftUI

/// Settings → Servers: the Herdr servers as a gallery, and under it the chosen server's parts,
/// one at a time: its connection (name, access key in the Keychain, Test, starter bots, Remove), its helper settings
/// (`HerdrHelperPolicySection`), its skill library (`HerdrSkillsSection`) and its project servers (`HerdrProjectsSection`). The last tile adds a server the same
/// three ways the setup window offers; a ready-made server is only announced. The agent program new bots start from
/// applies to every server.
struct HerdrSettingsSection: View {
    /// What of a server is showing.
    enum Part: String, CaseIterable, Identifiable {
        case connection = "Connection", helpers = "Helpers", skills = "Skills", projects = "Projects"
        var id: String { rawValue }
    }
    private static let addID = "+"

    @EnvironmentObject private var store: AppStore
    @AppStorage(HerdrBackend.templateKey) private var template = ""
    @State private var templates: [HerdrClient.Template] = []
    @State private var draft = HerdrServerDraft(kind: .ssh); @State private var adding = false; @State private var addResult = ""; @State private var addFailed = false
    /// The server whose parts show (nil: the first), or `addID` for the form that adds one.
    @State private var chosen: String?
    @State private var part: Part

    /// `chosen` and `part` (renders) open the section on one server's part, or on adding (`"+"`).
    init(chosen: String? = nil, part: Part = .connection) { _chosen = State(initialValue: chosen); _part = State(initialValue: part) }

    var body: some View {
        let servers = store.herdrServers, current = servers.first { $0.id == chosen } ?? (chosen == Self.addID ? nil : servers.first)
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                GroupHeading(title: "Servers", detail: "Where your bots run.")
                let tiles = servers.map { NamedChoice(id: $0.id, name: $0.name, note: $0.place == $0.name ? nil : $0.place) } + [NamedChoice(id: Self.addID, name: "Add a server")]
                TileGallery(items: tiles, minimum: 170, isSelected: { $0.id == (current?.id ?? Self.addID) }, name: \.name, select: { chosen = $0.id }) { tile in
                    HStack(spacing: 10) {
                        if let server = servers.first(where: { $0.id == tile.id }) { SymbolTile(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour, size: 28) }
                        else { SymbolTile(symbol: "plus", colour: AppColor.olive, size: 28) }
                        NameTile(name: tile.name, note: tile.note)
                    }
                }
            }
            if let current {
                VStack(alignment: .leading, spacing: 18) {
                    SegmentedChoice(title: "Part of \(current.name)", options: Part.allCases.map { ($0, $0.rawValue) }, selection: $part).frame(maxWidth: 480)
                    switch part {
                    case .connection: HerdrServerSection(server: current, canRemove: servers.count > 1) { templates = $0 }.id(current.id)
                    case .helpers: HerdrHelperPolicySection(server: current, named: servers.count > 1).id(current.id)
                    case .skills: HerdrSkillsSection(server: current, named: servers.count > 1).id(current.id)
                    case .projects: HerdrProjectsSection(server: current, named: servers.count > 1).id(current.id)
                    }
                }
            } else { addForm }
            // Known once a server was read (its Connection part does that when it shows, and on "Check connection").
            if !templates.isEmpty {
                SettingBlock(title: "New bots run on") {
                    HerdrTemplatePicker(selection: $template, templates: templates, defaultName: templates.first?.name, defaultNote: "Default")
                }
            }
        }
    }

    /// Adding a server: where it runs as a few large options, then that place's fields, each on its own.
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingBlock(title: "Where is it?") {
                VStack(spacing: 8) {
                    ForEach([(HerdrServer.Kind.local, SetupCopy.herdrLocalTitle, WizardCopy.localDetail), (.ssh, SetupCopy.herdrSSHTitle, WizardCopy.sshDetail), (.address, SetupCopy.herdrAddressTitle, WizardCopy.addressDetail)], id: \.0) { kind, title, detail in
                        OptionCard(symbol: kind.mark.symbol, colour: kind.mark.colour, title: title, detail: detail, selected: draft.kind == kind, select: { draft.kind = kind })
                    }
                    ReadyMadeServerNote()
                }
            }
            HerdrServerFields(draft: $draft, submit: add).frame(maxWidth: AppleMetrics.column)
            HStack(spacing: 10) {
                Button("Connect and add", action: add).buttonStyle(.appleProminent).controlSize(.large).disabled(adding || draft.problem != nil)
                if adding { ProgressView().controlSize(.small) }
                if let problem = draft.problem, addResult.isEmpty { Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if !addResult.isEmpty { StatusCard(kind: addFailed ? .warning : .good, title: addFailed ? "Could not add it" : "Added", detail: addResult) }
        }
    }

    private func add() {
        guard draft.problem == nil, !adding else { return }
        let draft = draft
        adding = true; addResult = ""; addFailed = false
        Task {
            switch await store.testSetupHerdr(draft) {
            case .connected(let server, let key, _):
                store.saveHerdrServer(server, token: key)
                addResult = "Added \(server.name)."; self.draft = HerdrServerDraft(kind: draft.kind)
            case .nothingHere(let port): addFailed = true; addResult = SetupCopy.herdrNothingHere(port: port) + " " + SetupCopy.herdrStartHelp
            case .failed(let line): addFailed = true; addResult = line
            }
            adding = false
        }
    }
}

/// One saved server's connection: its name typed beside its mark, where it is, its access key, Test, starter bots and Remove.
struct HerdrServerSection: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer; let canRemove: Bool
    /// Hands the templates a passed Test read to the picker below the list.
    let loaded: ([HerdrClient.Template]) -> Void
    @State private var name = ""; @State private var token = ""; @State private var result = ""; @State private var working = false
    @State private var failed = false
    @State private var confirmRemove = false
    @State private var showKey = false
    /// The service was removed from this Mac just now: what that did stays on screen.
    @State private var localRemoval = false
    /// A server reached by address has no key until one is pasted: its field is open.
    private var keyMissing: Bool { server.kind == .address && store.herdrToken(for: server).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                SymbolTile(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Name", text: $name, prompt: Text("Name")).textFieldStyle(.plain).font(.title2.bold()).onSubmit(rename).accessibilityLabel("Server name")
                        .padding(.vertical, 3).padding(.horizontal, 8).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).frame(maxWidth: 320)
                    if server.place != server.name { Text(server.place).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 8) }
                }
            }
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Check connection") { test() }.buttonStyle(.appleProminent).disabled(working)
                Button("Add a bot for each AI") { addStarters() }.disabled(working).help("Adds one bot for each AI this server has that no bot here uses yet.")
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if canRemove { Button("Remove…", role: .destructive) { confirmRemove = true }.disabled(working) }
            }.controlSize(.large)
            if working { StatusCard(kind: .working, title: "Checking \(server.name)…") }
            else if !result.isEmpty { StatusCard(kind: failed ? .warning : .good, title: result) }
            // The access key is found without typing on this Mac and over SSH, so few people ever see this field.
            QuietFold(title: "Advanced", isOpen: Binding(get: { showKey || keyMissing }, set: { showKey = $0 })) {
                StandaloneField(title: SetupCopy.herdrAccessKeyLabel, text: $token, prompt: tokenPrompt, secure: true).frame(maxWidth: AppleMetrics.column)
                    .onChange(of: token) { _, value in
                        let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if typed != store.keyStore.key(for: server.keyAccount) { store.setHerdrToken(typed, for: server) }
                    }
                // What setting this Mac up installed can be taken away again here.
                if server.kind == .local, store.localService.isPlaced || localRemoval { LocalServiceRemoval(shown: $localRemoval).padding(.top, 8) }
            }
        }
        .onAppear { name = server.name; token = store.keyStore.key(for: server.keyAccount) }
        // The real app reads what the server can run when its connection shows, so "New bots run on" needs no Check first.
        .task(id: server.id) { if store.launchWorkEnabled, let read = try? await store.herdrTemplates(on: server) { loaded(read) } }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeHerdrServer(server) }
        } message: { Text("Its bots stay and move to \(store.herdrServers.first { $0.id != server.id }?.name ?? "your other server"). Nothing on the server itself changes.") }
    }

    private var bots: Int { store.herdrBots(on: server).count }
    private var tokenPrompt: String {
        if !token.isEmpty { return "" }
        return store.herdrToken(for: server).isEmpty ? (server.kind == .ssh ? "Found on the server when you check the connection" : "Paste it here") : "Found for you"
    }
    private var caption: String {
        let count = "\(bots == 1 ? "1 bot runs" : "\(bots) bots run") here."
        switch server.kind {
        case .local: return count
        case .ssh: return "Connected over SSH; \(AppConstants.name) keeps the connection open. \(count)"
        case .address: return "Reached by its address, a port you forwarded to this Mac. \(count)"
        }
    }

    private func rename() {
        var changed = server; changed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !changed.name.isEmpty, changed != server { store.saveHerdrServer(changed, token: nil) }
    }

    private func test() {
        rename(); working = true; result = ""; failed = false
        Task {
            do {
                let tested = try await store.testHerdrServer(server)
                if let found = tested.token { store.setHerdrToken(found, for: server); token = found }
                result = tested.line
                loaded(try await store.herdrTemplates(on: server))
            } catch { result = error.localizedDescription; failed = true }
            working = false
        }
    }

    private func addStarters() {
        working = true; result = ""; failed = false
        Task {
            do {
                let added = try await store.addHerdrStarterBots(on: server)
                result = added.isEmpty ? "Every AI on this server already has a bot." : "Added \(added.joined(separator: " and ")). Find them in the sidebar."
            } catch { result = error.localizedDescription; failed = true }
            working = false
        }
    }
}

/// This Mac's own service, with the one thing a person can do to it here: stop it and remove what setting this Mac
/// up installed. It asks first, and afterwards says what it removed and what it kept, in the service's own sentences.
struct LocalServiceRemoval: View {
    @EnvironmentObject private var store: AppStore
    /// Stays true once something was removed, so the result is not taken off the screen with the program.
    @Binding var shown: Bool
    @State private var confirm = false
    @State private var working = false
    @State private var removal: HerdrLocalRemoval?
    @State private var failure: String?
    /// A render shows a finished removal without running one.
    var preset: HerdrLocalRemoval? = nil

    var body: some View {
        SettingBlock(title: SetupCopy.localServiceTitle, detail: SetupCopy.localServiceDetail) {
            VStack(alignment: .leading, spacing: 10) {
                if (preset ?? removal) == nil { Button(SetupCopy.localRemove, role: .destructive) { confirm = true }.disabled(working) }
                if working { StatusCard(kind: .working, title: SetupCopy.localRemoving) }
                else if let removal = preset ?? removal {
                    StatusCard(kind: .good, title: SetupCopy.localRemoved, detail: (removal.did + removal.kept.map(SetupCopy.localKept)).joined(separator: "\n"))
                } else if let failure { StatusCard(kind: .warning, title: failure) }
            }.frame(maxWidth: AppleMetrics.column, alignment: .leading)
        }
        .confirmationDialog(SetupCopy.localRemoveQuestion, isPresented: $confirm) {
            Button(SetupCopy.localRemoveConfirm, role: .destructive, action: remove)
        } message: { Text(SetupCopy.localRemoveDetail) }
    }

    private func remove() {
        working = true; failure = nil; shown = true
        Task {
            do { removal = try await store.removeLocalService() } catch { failure = error.localizedDescription }
            working = false
        }
    }
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
    @State private var showAdvanced = false
    @Environment(\.inspectorStartsAdvanced) private var renderOpen
    /// The server's lists were read (a render passes them in); until then the default entries cannot be named.
    @State private var listed: Bool
    @State private var switchTarget: HerdrPickerTarget?
    @State private var switching = false
    @State private var confirmFresh = false
    private let preset: Bool

    /// `templates` and `models` (renders and tests) show a read without making one.
    init(bot: Bot, templates: [HerdrClient.Template]? = nil, models: [HerdrClient.Template.Model] = []) {
        self.bot = bot; preset = templates != nil
        _templates = State(initialValue: templates ?? []); _models = State(initialValue: models); _listed = State(initialValue: templates != nil)
    }

    private var shared: String? { store.defaults.string(forKey: HerdrBackend.templateKey) }
    /// The template this bot would start from now: its own, else the one for new bots, else the first available.
    private var effective: HerdrClient.Template? { HerdrAgentReading.template(own: template, shared: shared, in: templates).template }

    /// What "no choice of its own" means here: the agent program new bots use, else the server's first.
    private var defaultTemplate: HerdrClient.Template? { HerdrAgentReading.template(own: nil, shared: shared, in: templates).template }

    var body: some View {
        let servers = store.herdrServers, reading = store.herdrAgentReadings[bot.id]
        VStack(alignment: .leading, spacing: 22) {
            SettingBlock(title: "AI", detail: listed ? (templates.isEmpty ? "This server has no AI set up yet." : nil) : "Checking…") {
                HerdrTemplatePicker(selection: $template, templates: templates, defaultName: defaultTemplate?.name, defaultNote: "Default")
            }
            .onChange(of: template) { _, value in
                guard loaded, value != (store.defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? "") else { return }
                store.setHerdrTemplate(value, for: bot); model = HerdrModelChoice.recommended; store.setHerdrModel(model, for: bot)
                Task { await loadModels(); await applyChoice() }
            }
            if effective?.takesModel == true {
                // No choice of its own: the first model the server offers, which the bot's next agent is started on.
                SettingBlock(title: "Model", detail: listed ? nil : "Checking…") {
                    HerdrModelPicker(model: Binding(get: { model }, set: { value in
                        guard loaded, value != model else { return }
                        model = value
                        store.setHerdrModel(value, for: bot)
                        Task { await switchCurrentModel() }
                    }), program: effective?.modelAgent ?? effective?.programName, models: models)
                }
                .disabled(switching || store.isWorking(bot))
            } else if listed, effective != nil {
                SettingBlock(title: "Model", detail: HerdrAgentReading.programPicks) { EmptyView() }
            }
            if let running = reading?.runningLine {
                StatusCard(kind: reading?.pendingLine == nil ? .info : .warning, title: running, detail: reading?.pendingLine)
            }
            if !note.isEmpty { Text(note).font(.callout).textSelection(.enabled) }
            if reading?.session != nil, reading?.activeTemplate == effective?.name,
               let program = effective?.modelAgent, ["OpenCode", "Claude Code", "Codex"].contains(program),
               reading?.pendingLine != nil || reading?.running == .unknown || !note.isEmpty && reading?.confirmed != true {
                Button("Switch in this conversation") { Task { await switchCurrentModel() } }
                    .disabled(switching || store.isWorking(bot))
            }
            // What few people change: both are on for every bot.
            QuietFold(title: "Advanced", isOpen: Binding(get: { showAdvanced || renderOpen }, set: { showAdvanced = $0 })) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingBlock(title: "New conversation", detail: "Start \(bot.name) with empty context. Earlier messages stay visible here.") {
                        Button(HerdrAgentReading.startFresh) { confirmFresh = true }.disabled(restarting || switching || store.isWorking(bot))
                    }
                    if servers.count > 1 {
                        // Another server has its own agent programs and models, so both choices start over there.
                        SettingBlock(title: "Server") {
                            TileGallery(items: servers, minimum: 130, isSelected: { $0.id == serverID }, name: \.name, select: { serverID = $0.id }) { server in
                                NameTile(name: server.name, symbol: server.kind.mark.symbol)
                            }
                        }
                        .onChange(of: serverID) { _, value in
                            guard loaded, value != store.herdrServer(for: bot).id else { return }
                            // Projects belong to a Herdr server too: the ones chosen on the server it leaves do not go with it.
                            store.setHerdrServer(value, for: bot); template = ""; model = ""; store.setHerdrTemplate("", for: bot); store.setHerdrModel("", for: bot); store.setHerdrProjects([], for: bot)
                            Task { await loadTemplates(); await loadModels(); await applyChoice() }
                        }
                    }
                    SettingSwitch(title: "Read new messages mid-answer", detail: "Off: a message you send while \(bot.name) is answering waits until the answer ends.",
                                  isOn: Binding(get: { steers }, set: { steers = $0; store.setHerdrSteers($0, for: bot) }))
                    // It is started when its chat opens, so the first message does not wait for it.
                    let ahead = store.herdrStartsAhead(for: bot)
                    SettingSwitch(title: "Keep \(bot.name) ready", detail: AppStore.keepsReadyCaption(bot: bot.name, program: effective?.modelAgent ?? effective?.programName, available: ahead),
                                  isOn: Binding(get: { ahead && store.herdrKeepsReady(bot) }, set: { store.setHerdrKeepsReady($0, for: bot) }))
                        .disabled(!ahead)
                }
            }
        }
        .confirmationDialog("Start a new conversation for \(bot.name)?", isPresented: $confirmFresh) {
            Button(HerdrAgentReading.startFresh, role: .destructive) { restart() }
        }
        .sheet(item: $switchTarget, onDismiss: { Task { await store.refreshHerdrAgentReading(for: bot) } }) { target in
            HerdrTerminalSheet(bot: bot, agent: target.agent, target: target) {
                note = "Switched to \(target.record.label) in this conversation."
            }
        }
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

    /// The agent program or model was changed. An agent that was started ahead of time and has not been written to
    /// yet is replaced by one that starts as now chosen, so the choice applies at once for a bot nobody has written
    /// to; an agent that holds a conversation keeps running until "Start a fresh agent".
    private func applyChoice() async {
        if store.launchWorkEnabled { await store.herdrChoiceChanged(for: bot) }
        await store.refreshHerdrAgentReading(for: bot)
    }

    private func switchCurrentModel() async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        note = ""
        let server = store.herdrServer(for: bot), choice = store.herdrModel(for: bot)
        guard let reading = await store.refreshHerdrAgentReading(for: bot, requireFresh: true) else {
            note = "Couldn’t check the running session. Your model choice is saved for the next launch."
            return
        }
        guard choice == store.herdrModel(for: bot), server == store.herdrServer(for: bot) else { return }
        guard let session = reading.session, let core = reading.core else { await applyChoice(); return }
        guard let runtime = reading.runtime, reading.activeTemplate == runtime.name else {
            note = "The selected agent program will be used for a new conversation."
            return
        }
        do {
            if runtime.modelAgent == "OpenCode" {
                let client = try store.herdrClient(for: server)
                let state = try await client.selectModel(reading.model?.id, for: session, core: core)
                if let id = state.effective {
                    let label = models.first { $0.id == id }?.label ?? id
                    store.rememberModel(.init(server: server.id, core: core, address: session.address, created: session.createdMs, id: id, label: label), for: bot)
                    note = "Switched to \(label) in this conversation."
                }
                await store.refreshHerdrAgentReading(for: bot)
            } else if let program = runtime.modelAgent, ["Claude Code", "Codex"].contains(program), let selected = reading.model {
                let record = HerdrModelConfirmation(server: server.id, core: core, address: session.address, created: session.createdMs, id: selected.id, label: HerdrAgentReading.name(selected))
                switchTarget = HerdrPickerTarget(record: record, agent: session, program: program)
            } else { note = "This agent program applies the selected model on its next launch." }
        } catch { note = error.localizedDescription }
    }

    private func restart() {
        restarting = true; note = ""
        Task {
            do {
                let closed = try await store.restartHerdrAgent(for: bot)
                // With "Keep its agent ready" on, the fresh agent starts now instead of with the next message.
                let starting = store.launchWorkEnabled && store.warmHerdrAgent(for: bot) != nil
                note = Self.restartNote(closed: closed, starting: starting)
            } catch { note = error.localizedDescription }
            await store.refreshHerdrAgentReading(for: bot)
            restarting = false
        }
    }

    nonisolated static func restartNote(closed: Bool, starting: Bool) -> String {
        switch (closed, starting) {
        case (true, true): "Done. It is starting fresh now."
        case (true, false): "Done. It starts fresh with your next message."
        case (false, true): "It was not running. It is starting now."
        case (false, false): "It was not running. It starts with your next message."
        }
    }
}

/// Overview's cards for a Herdr bot: the server its agent runs on, the role of a main bot, and the agent program and
/// model by the server's names for them (a press opens the Model tab, where both are chosen).
struct HerdrOverviewSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        let server = store.herdrServer(for: bot)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Runs on \(server.name)").font(.headline)
                    if server.place != server.name { Text(server.place).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }.frame(minHeight: 32)
            }.appleCard(padding: 12)
            if store.createsHerdrBots(bot) {
                HStack(alignment: .top, spacing: 12) {
                    SymbolTile(symbol: "star.fill", colour: AppColor.clay, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Main bot").font(.headline)
                        Text("It can set up other bots, and other bots ask it.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.appleCard(padding: 12)
            }
            if let reading = store.herdrAgentReadings[bot.id] {
                Button { store.infoTab = .model } label: {
                    HStack(alignment: .top, spacing: 8) {
                        fact("AI", reading.runtime?.label ?? "None set up", isDefault: reading.runtime != nil && !reading.runtimeIsOwn, symbol: "terminal.fill", colour: AppColor.olive)
                        fact("Model", reading.model.map(HerdrAgentReading.name) ?? HerdrAgentReading.programPicks, isDefault: reading.model != nil && !reading.modelIsOwn, symbol: "cpu.fill", colour: AppColor.plum)
                    }
                }.buttonStyle(.plain).help("Change them under Model").accessibilityLabel(reading.summary).accessibilityHint("Opens Model")
                if let running = reading.runningLine, reading.pendingLine != nil || reading.running == .unstated || reading.running == .unknown {
                    StatusCard(kind: reading.pendingLine == nil ? .info : .warning, title: running, detail: reading.pendingLine)
                } else if case .model(_, let label) = reading.running {
                    Text("Running on \(label) now.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Only the real app reads on its own; a preview or test store shows what it was given.
        .task(id: bot.id) { if store.launchWorkEnabled { await store.refreshHerdrAgentReading(for: bot) } }
    }

    /// One fact as a tile: what it is, its value in full by the server's name, and "Default" when the bot did not choose it.
    private func fact(_ title: String, _ value: String, isDefault: Bool, symbol: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SymbolTile(symbol: symbol, colour: colour, size: 20)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            if isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).appleCard(padding: 10)
    }
}

/// The agent programs the bridge reported as a gallery, plus the saved choice when it is not among them (not loaded
/// yet, or removed). `selection` empty means no choice of its own: the tile of `defaultName` is the chosen one and
/// says so (`defaultNote`), and pressing it goes back to no choice.
struct HerdrTemplatePicker: View {
    @Binding var selection: String
    let templates: [HerdrClient.Template]
    /// The template an empty selection resolves to; nil when the server's list is not read yet.
    let defaultName: String?
    let defaultNote: String

    var body: some View {
        let unlisted = !selection.isEmpty && !templates.contains(where: { $0.name == selection }) ? [NamedChoice(id: selection, name: selection, note: templates.isEmpty ? nil : "No longer offered")] : []
        let labels = HerdrProgramName.labels(for: templates)
        let choices = templates.map { NamedChoice(id: $0.name, name: labels[$0.name] ?? $0.label, note: $0.name == defaultName ? defaultNote : nil) } + unlisted
        if !choices.isEmpty {
            TileGallery(items: choices, minimum: 150, isSelected: { selection.isEmpty ? $0.id == defaultName : $0.id == selection }, name: \.name,
                        select: { selection = $0.id == defaultName ? "" : $0.id }) { NameTile(name: $0.name, note: $0.note) }
        }
    }
}


/// The empty legacy choice follows the first server model. Recommended follows the selected agent.
struct HerdrModelPicker: View {
    @Binding var model: String
    let program: String?
    let models: [HerdrClient.Template.Model]
    @State private var query = ""
    @State private var typedID = ""
    @State private var enteringID = false

    var body: some View {
        let suggestion = HerdrModelChoice.suggested(program: program, offered: models)
        let recommended = suggestion.map { "Recommended · " + HerdrAgentReading.name($0) } ?? "Recommended · agent default"
        let visible = models.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || ($0.label ?? "").localizedCaseInsensitiveContains(query) || $0.id == model }
        VStack(alignment: .leading) {
            if models.count > 12 {
                TextField("Find a provider or model", text: $query)
            }
            Picker("Model", selection: $model) {
                Text(recommended).tag(HerdrModelChoice.recommended)
                if model.isEmpty { Text("Server default").tag("") }
                if !model.isEmpty, model != HerdrModelChoice.recommended, !models.contains(where: { $0.id == model }) {
                    Text(model + " · unlisted").tag(model)
                }
                ForEach(visible, id: \.id) { item in
                    Text(program == "OpenCode" ? item.id : HerdrAgentReading.name(item)).tag(item.id)
                }
            }.labelsHidden().accessibilityLabel("Model").pickerStyle(.menu)
            if program?.caseInsensitiveCompare("OpenCode") == .orderedSame {
                DisclosureGroup("Enter a provider/model ID", isExpanded: $enteringID) {
                    HStack {
                        TextField("provider/model", text: $typedID)
                        Button("Use ID") {
                            if let id = HerdrModelChoice.apiModelID(typedID) {
                                model = id
                                enteringID = false
                            }
                        }.disabled(HerdrModelChoice.apiModelID(typedID) == nil)
                    }
                }
            }
        }
    }
}

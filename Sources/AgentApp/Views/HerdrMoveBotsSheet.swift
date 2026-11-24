import SwiftUI

struct HerdrMoveBotsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let source: HerdrServer
    var initialBot: UUID? = nil

    private enum Step { case destination, bots, summary }
    @State private var step = Step.destination
    @State private var destination: HerdrServer?
    @State private var templates: [HerdrClient.Template] = []
    @State private var checked = false
    @State private var addServer = false
    @State private var draft = HerdrServerDraft(kind: .ssh)
    @State private var draftID = HerdrServerList.newID()
    @State private var loginServer: HerdrServer?
    @State private var offerInstall = false
    @State private var selected: Set<UUID> = []
    @State private var useOneAI = false
    @State private var template = ""
    @State private var model = HerdrModelChoice.recommended
    @State private var models: [HerdrClient.Template.Model] = []
    @State private var carryHistory = true
    @State private var stopIdleAgents = true
    @State private var working: String?
    @State private var problem: String?
    @State private var record: HerdrServerMoveRecord?
    @State private var undone = false

    private var destinations: [HerdrServer] { store.herdrServers.filter { $0.id != source.id } }
    private var bots: [Bot] { store.movableHerdrBots(on: source) }
    private var currentSelection: Set<UUID> { selected.intersection(bots.map(\.id)) }
    private var defaultTemplate: HerdrClient.Template? { store.herdrMoveDefault(in: templates) }
    private var chosenTemplate: HerdrClient.Template? {
        template.isEmpty ? defaultTemplate : templates.first { $0.name == template }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move bots to a server / VPS").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("From \(source.name)").foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .destination: destinationStep
                    case .bots: botStep
                    case .summary: summaryStep
                    }
                    if let working { StatusCard(kind: .working, title: working) }
                    if let problem { StatusCard(kind: .warning, title: problem) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer.padding(18)
        }
        .frame(width: 580, height: 630)
        .interactiveDismissDisabled(working != nil)
        .onAppear {
            if let initialBot { selected = [initialBot] }
            else if source.kind == .local { selected = Set(bots.map(\.id)) }
        }
        .onChange(of: draft) { _, _ in offerInstall = false }
        .onDisappear {
            if let unsaved = draft.server(id: draftID) { store.abandonSetupHerdr(unsaved) }
        }
        .sheet(item: $loginServer) { server in
            SSHLoginSheet(server: server) { signedIn in
                if addServer || destinations.isEmpty {
                    draft.sshDestination = "\(signedIn.sshUser)@\(signedIn.sshHost)"
                    connect()
                } else {
                    check(signedIn, updating: server)
                }
            }
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if destinations.isEmpty || addServer {
                Text("Connect your VPS / server").font(.headline)
                Picker("Connect using", selection: $draft.kind) {
                    Text("SSH").tag(HerdrServer.Kind.ssh)
                    Text("Address").tag(HerdrServer.Kind.address)
                }.pickerStyle(.segmented)
                HerdrServerFields(draft: $draft, part: .main, submit: connect)
                if draft.kind == .ssh {
                    DisclosureGroup("Connection details") {
                        HerdrServerFields(draft: $draft, part: .details, submit: connect).padding(.top, 8)
                    }
                }
                HStack {
                    Button("Connect and add", action: connect)
                        .buttonStyle(.borderedProminent).disabled(draft.problem != nil)
                    if offerInstall {
                        Button("Set up over SSH") { connect(install: true) }
                            .help("Install the SwarmHub service and set up Herdr on this server.")
                    }
                    if !destinations.isEmpty {
                        Button("Use a saved server") { addServer = false; problem = nil }
                    }
                }
            } else {
                Text("Destination server").font(.headline)
                ForEach(destinations) { server in
                    OptionCard(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour,
                               title: server.name, detail: server.place,
                               selected: destination?.id == server.id, select: { check(server) })
                }
                if let destination, checked {
                    let labels = HerdrProgramName.labels(for: templates)
                    StatusCard(kind: .good, title: "Connected to \(destination.name)",
                               detail: templates.isEmpty ? "Set up an AI on this server before moving bots."
                                   : "Available AIs: " + templates.map { labels[$0.name] ?? $0.label }.joined(separator: ", "))
                }
                HStack {
                    Button("Add a VPS / server…") { addServer = true; checked = false; problem = nil }
                    if let destination { Button("Check connection again") { check(destination) } }
                }
            }
        }
        .disabled(working != nil)
    }

    private var botStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Choose bots for \(destination?.name ?? "the destination")").font(.headline)
                Spacer()
                Button("Select all") { selected = Set(bots.map(\.id)) }
                Button("Select none") { selected.removeAll() }
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(bots) { bot in
                    Toggle(isOn: Binding(get: { selected.contains(bot.id) }, set: { on in
                        if on { selected.insert(bot.id) } else { selected.remove(bot.id) }
                    })) {
                        HStack {
                            Text(bot.name)
                            if store.createsHerdrBots(bot) { HerdrMainBotStar(label: "Main bot", size: 13) }
                            Spacer()
                            if store.herdrMoveIsBusy(bot) {
                                Text(store.isAnswering(bot) || store.herdrStreaming.contains(bot.id) ? "Answering" : "Busy")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }.toggleStyle(.checkbox)
                }
            }
            Text("Bots with active work stay on \(source.name) until you move them again. Project access is cleared for moved bots.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingBlock(title: "AI and model on the destination") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("AI and model on the destination", selection: $useOneAI) {
                        Text("Keep matching AI where available").tag(false)
                        Text("Put all moved bots on one AI & model").tag(true)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    if useOneAI {
                        HerdrTemplatePicker(selection: $template, templates: templates, defaultName: defaultTemplate?.name, defaultNote: "Default")
                        if let chosenTemplate, chosenTemplate.takesModel {
                            HerdrModelPicker(model: $model, program: chosenTemplate.modelAgent ?? chosenTemplate.programName, models: models)
                                .id(chosenTemplate.name)
                        }
                    } else if let defaultTemplate {
                        Text("Keeps models the destination offers. Otherwise it uses the Recommended model, with \(defaultTemplate.label) as the default AI.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Toggle("Carry over recent conversation history", isOn: $carryHistory)
            Toggle("Stop old idle agents on source server", isOn: $stopIdleAgents)
        }
        .disabled(working != nil)
        .task(id: chosenTemplate?.name) { await loadModels() }
        .onChange(of: template) { _, _ in model = HerdrModelChoice.recommended; models = [] }
    }

    @ViewBuilder private var summaryStep: some View {
        if let record {
            if undone {
                StatusCard(kind: .good, title: "Move undone",
                           detail: "\(AppStore.botCount(record.changes.count)) returned to \(source.name) with their previous AI, model, and project settings.")
            } else if record.changes.isEmpty {
                StatusCard(kind: .warning, title: "No bots moved", detail: "Try again when the selected bots finish their work.")
            } else {
                let place = record.destination.name
                StatusCard(kind: .good, title: "Moved \(AppStore.botCount(record.changes.count)) to \(place).",
                           detail: record.carryHistory ? "Their next replies will run on \(place) with your conversation carried over."
                               : "Their next replies will run on \(place).")
                if record.changes.contains(where: { $0.wasMain && !$0.isMain }) {
                    Text("\(place) kept its existing Main bot.")
                }
                if record.cleanup.stopped > 0 {
                    Text("Stopped \(record.cleanup.stopped) idle \(record.cleanup.stopped == 1 ? "agent" : "agents") on \(source.name).")
                }
                if !record.cleanup.busy.isEmpty {
                    Text("Left source agents running for \(record.cleanup.busy.joined(separator: ", ")). They still had work or their idle status was unavailable.")
                }
                if !record.cleanup.failed.isEmpty {
                    Text("Couldn’t finish stopping source agents for \(record.cleanup.failed.joined(separator: ", ")).")
                }
            }
            if !undone, !record.skipped.isEmpty {
                Text("Still on \(source.name) because they were busy: \(record.skipped.joined(separator: ", ")).")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            switch step {
            case .destination:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { step = .bots; problem = nil }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(addServer || !checked || templates.isEmpty)
            case .bots:
                Button("Back") { step = .destination; problem = nil }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move \(AppStore.botCount(currentSelection.count))", action: move)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(currentSelection.isEmpty || (useOneAI && chosenTemplate == nil))
            case .summary:
                if let record, !undone {
                    if record.changes.isEmpty { Button("Back") { step = .bots; problem = nil } }
                    else {
                        Button("Undo") {
                            do { try store.undoHerdrMove(record); undone = true; problem = nil }
                            catch { problem = error.localizedDescription }
                        }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .disabled(working != nil)
    }

    private func check(_ server: HerdrServer, updating previous: HerdrServer? = nil) {
        guard working == nil else { return }
        destination = previous ?? server
        checked = false
        problem = nil
        working = "Checking \(server.name)…"
        Task {
            defer { working = nil }
            do {
                let tested = try await store.testHerdrServer(server)
                let workspace = try await store.herdrMoveWorkspace(on: server, key: tested.token)
                if previous != nil || tested.token != nil { store.saveHerdrServer(server, token: tested.token) }
                setDestination(server, workspace: workspace)
            } catch {
                if server.kind == .ssh, HerdrTunnel.offersPassword(error) { loginServer = server }
                else { problem = HerdrSetupProblem.of(error).line(for: server) }
            }
        }
    }

    private func connect() { connect(install: false) }

    private func connect(install: Bool) {
        guard working == nil, draft.problem == nil else { return }
        let typed = draft
        let match = store.matchingHerdrServer(for: typed)
        guard match?.id != source.id else { problem = "Choose a server other than \(source.name)."; return }
        let id = match?.id ?? draftID
        problem = nil
        offerInstall = false
        working = install ? "Setting up SwarmHub over SSH…" : "Checking the connection…"
        Task {
            defer { working = nil }
            do {
                if install, let server = typed.server(id: id) { try await store.installHerdrMoveDestination(server) }
                switch await store.testSetupHerdr(typed, serverID: id) {
                case .connected(let server, let key, _):
                    let workspace = try await store.herdrMoveWorkspace(on: server, key: key)
                    store.saveHerdrServer(server, token: key)
                    draft = HerdrServerDraft(kind: typed.kind)
                    draftID = HerdrServerList.newID()
                    setDestination(server, workspace: workspace)
                case .sshLoginRequired(let server): loginServer = server
                case .nothingHere(let port): problem = SetupCopy.herdrNothingHere(port: port)
                case .failed(let line):
                    problem = line
                    if typed.kind == .ssh, let server = typed.server(id: id) {
                        offerInstall = [HerdrSetupProblem.sshNoService, .sshNoAnswer, .unreachable].contains { $0.line(for: server) == line }
                    }
                }
            } catch { problem = error.localizedDescription; offerInstall = install }
        }
    }

    private func setDestination(_ server: HerdrServer, workspace: HerdrClient.Workspace) {
        destination = server
        templates = workspace.templates.filter { $0.error == nil }
        checked = true
        addServer = false
        template = ""
        models = []
        model = HerdrModelChoice.recommended
    }

    private func loadModels() async {
        guard let destination, let chosenTemplate, chosenTemplate.takesModel else { return }
        let offered = (try? await store.herdrClient(for: destination).models(for: chosenTemplate)) ?? chosenTemplate.models ?? []
        guard !Task.isCancelled else { return }
        models = offered
    }

    private func move() {
        guard let destination, working == nil else { return }
        let mapping: HerdrMoveMapping
        if useOneAI {
            guard let chosenTemplate else { return }
            mapping = .one(template: chosenTemplate.name, model: model)
        } else { mapping = .matching }
        let selection = currentSelection
        problem = nil
        working = "Moving bots to \(destination.name)…"
        Task {
            defer { working = nil }
            do {
                record = try await store.moveHerdrBots(selection, from: source, to: destination, mapping: mapping,
                                                       carryHistory: carryHistory, stopIdleAgents: stopIdleAgents)
                step = .summary
            } catch { problem = error.localizedDescription }
        }
    }
}

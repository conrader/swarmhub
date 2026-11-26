import SwiftUI

// Project servers and projects of one Herdr server (`HerdrProjectsModel`): in Settings → Servers → Projects, in the setup wizard's optional step, and in a bot's settings and Details, where the person chooses
// which projects that bot may use.

/// Adding a project server, one thing at a time: the Herdr server's public key to paste on the project server, how
/// to reach it, the fingerprint of a host the Herdr server has not seen (trusted only by its own button), and the
/// result in the workspace's words, with what was installed there.
struct HerdrAddMachineFlow: View {
    @ObservedObject var model: HerdrProjectsModel
    /// The Herdr server that will log in to the project server.
    let serverName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.adding {
            case .fields: fields
            case .working: StatusCard(kind: .working, title: HerdrProjectsCopy.adding, detail: HerdrProjectsCopy.addingDetail)
            case .trust(let question): trust(question)
            case .done(let message, let warnings):
                StatusCard(kind: .good, title: message) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        Button(HerdrProjectsCopy.another) { model.addAgain() }.padding(.top, 2)
                    }
                }
            case .failed(let why):
                StatusCard(kind: .warning, title: HerdrProjectsCopy.notAdded, detail: why) { Button("Try again") { model.addAgain() }.padding(.top, 4) }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        if let problem = model.listing.problem, !model.canAdd { StatusCard(kind: .warning, title: problem) }
        SettingBlock(title: HerdrProjectsCopy.keyTitle, detail: HerdrProjectsCopy.keyDetail(serverName)) {
            if let key = model.publicKey {
                CopyBox(text: key, lineLimit: 3)
                if let place = model.keys?.whereToPaste, !place.isEmpty { Text(place).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            } else if model.keys?.canCreate == true {
                HStack(spacing: 10) {
                    Text(HerdrProjectsCopy.keyMissing).font(.callout).foregroundStyle(.secondary)
                    Button(HerdrProjectsCopy.keyCreate) { Task { await model.makeKey() } }.disabled(model.makingKey)
                    if model.makingKey { ProgressView().controlSize(.small) }
                }
            } else if model.phase == .ready {
                Text(model.keys?.problem ?? HerdrProjectsCopy.keyMissing).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.keys?.problem, model.publicKey != nil || model.keys?.canCreate == true { Text(problem).font(.caption).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true) }
        }
        SettingBlock(title: HerdrProjectsCopy.addressTitle, detail: HerdrProjectsCopy.addressDetail) {
            HStack(alignment: .top, spacing: 10) {
                StandaloneField(title: HerdrProjectsCopy.addressLabel, text: $model.target, prompt: HerdrProjectsCopy.addressPrompt, monospaced: true, submit: add)
                StandaloneField(title: HerdrProjectsCopy.nameLabel, text: $model.name, prompt: HerdrProjectsCopy.namePrompt, submit: add).frame(width: 170)
            }
            if let installs = model.listing.adding, !installs.isEmpty { Text(installs).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Button(HerdrProjectsCopy.add, action: add).controlSize(.large).disabled(model.trimmedTarget.isEmpty || !model.canAdd).padding(.top, 4)
        }
    }

    private func add() { if !model.trimmedTarget.isEmpty, model.canAdd { Task { await model.add() } } }

    /// The Herdr server has never connected to this host: its fingerprints, how to check one, and the one button that trusts it.
    @ViewBuilder private func trust(_ question: HerdrRefusal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: "touchid", colour: AppColor.clay, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(HerdrProjectsCopy.trustTitle).font(.headline)
                    Text(question.hostKeys.isEmpty ? question.message : HerdrProjectsCopy.hostKeyQuestion(question.message))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(question.hostKeys) { key in
                VStack(alignment: .leading, spacing: 8) {
                    Text(key.type).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(key.fingerprint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button(question.hostKeys.count > 1 ? "\(HerdrProjectsCopy.trust) by this key" : HerdrProjectsCopy.trust) { Task { await model.trust(key) } }
                        .accessibilityLabel("\(HerdrProjectsCopy.trust): \(key.type) \(key.fingerprint)")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if !question.hostKeys.isEmpty { Text(HerdrProjectsCopy.trustNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            // Leaving without trusting adds nothing: the Herdr server has written no key.
            Button(HerdrProjectsCopy.dontTrust) { model.addAgain() }
        }.appleCard(padding: 16)
    }
}

/// One project server as a card: its name and state, the workspace's own warnings, and (in Settings) its projects
/// as rows inside it, each with a small menu, and a way to add one. What is rarely needed (Connect again while it is
/// connected, Remove) is in the card's menu; a server that is offline shows Connect again as a button.
struct HerdrMachineCard: View {
    @ObservedObject var model: HerdrProjectsModel
    let machine: HerdrMachine
    /// Settings lists the server's projects inside its card and edits them there; the wizard lists them on their own.
    var listsProjects = false
    var removeProject: (HerdrProject) -> Void = { _ in }
    @State private var confirmRemove = false

    private var projects: [HerdrProject] { model.projects.filter { $0.machine == machine.name } }
    /// The form for a project of this server is open (a new one, or one of its own being changed).
    private var editing: Bool { model.draft.map { $0.machine == machine.name } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SymbolTile(symbol: "externaldrive.connected.to.line.below.fill", colour: machine.reachable ? AppColor.sage : .gray, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(machine.name).font(.headline)
                        FactChip(text: machine.stateLine, symbol: machine.reachable ? "checkmark.circle.fill" : "exclamationmark.circle.fill", colour: machine.reachable ? AppColor.good : AppColor.caution)
                    }
                    Text(machine.target).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if model.busy.contains(machine.name) { ProgressView().controlSize(.small) }
                Menu {
                    Button("Connect again") { Task { await model.reconnect(machine) } }
                    Divider()
                    Button("Remove \(machine.name)…", role: .destructive) { confirmRemove = true }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy.contains(machine.name))
                    .help("More for \(machine.name)").accessibilityLabel("More for \(machine.name)")
            }
            if let worker = machine.worker {
                VStack(alignment: .leading, spacing: 4) {
                    if let message = worker.admission.message {
                        Label(message, systemImage: worker.admission.status == "stop" ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(AppColor.caution)
                    } else if worker.admission.status == "eligible" {
                        Label("Eligible for heavy fixture work", systemImage: "checkmark.circle")
                            .foregroundStyle(AppColor.good)
                    }
                    if let disk = worker.admission.disk { Text(disk.line).foregroundStyle(.secondary) }
                    if let id = worker.workerId, let fingerprint = worker.hostFingerprint {
                        Text("\(id) · \(fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let probe = worker.probe {
                        Text("Probe taken \(probe.observedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(machine.warnings.filter { $0 != machine.worker?.admission.message }, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let said = model.said[machine.name] { Text(said).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !machine.reachable { Button("Connect again") { Task { await model.reconnect(machine) } }.disabled(model.busy.contains(machine.name)) }
            if listsProjects {
                Divider()
                ForEach(projects) { project in
                    if model.draft?.id == project.id { HerdrProjectEditor(model: model) }
                    else {
                        HerdrProjectRow(project: project) {
                            Menu {
                                Button("Change…") { model.edit(project) }
                                Divider()
                                Button("Remove \(project.name)…", role: .destructive) { removeProject(project) }
                            } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, height: 24).contentShape(Rectangle()) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More for \(project.name)").accessibilityLabel("More for \(project.name)")
                        }
                    }
                }
                if editing, model.draft?.id == nil { HerdrProjectEditor(model: model) }
                else if model.draft == nil {
                    if !model.projectProblem.isEmpty { Text(model.projectProblem).font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    Button { model.newProject(on: machine.name) } label: { Label(projects.isEmpty ? "Add its first project" : "Add a project", systemImage: "plus") }.buttonStyle(.borderless)
                }
            } else {
                Text(machine.projects.isEmpty ? HerdrProjectsCopy.noProjects : "Projects: \(machine.projects.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .appleCard()
        .confirmationDialog("Remove \(machine.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.remove(machine) } }
        } message: { Text("Your bots can no longer work on \(machine.name). Nothing on that server is deleted.") }
    }
}

/// One project inside its server's card: a folder, its name, its note, and where it is.
struct HerdrProjectRow<Trailing: View>: View {
    let project: HerdrProject
    @ViewBuilder let trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(AppColor.clay).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.system(size: 13, weight: .semibold))
                Text(project.note.isEmpty ? project.folder : "\(project.note) · \(project.folder)").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }.frame(minHeight: 30).accessibilityElement(children: .contain)
    }
}

/// The project being written: its name, its server (a gallery when there are several), its folder and an optional
/// note for the bots, each field on its own. The workspace checks that the folder is there before it saves.
struct HerdrProjectEditor: View {
    @ObservedObject var model: HerdrProjectsModel
    /// Called with the project the workspace took.
    var saved: (HerdrProject) -> Void = { _ in }
    var canCancel = true

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.id == nil ? HerdrProjectsCopy.newProject : "Change \(draft.name)").font(.headline)
                if model.machines.count > 1 {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(HerdrProjectsCopy.projectServer).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        TileGallery(items: model.machines, minimum: 120, isSelected: { $0.name == draft.machine }, name: \.name, select: { model.draft?.machine = $0.name }) { NameTile(name: $0.name) }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    StandaloneField(title: HerdrProjectsCopy.projectName, text: binding(\.name), prompt: HerdrProjectsCopy.projectNamePrompt, submit: save).frame(width: 150)
                    StandaloneField(title: HerdrProjectsCopy.projectFolder, text: binding(\.folder), prompt: HerdrProjectsCopy.projectFolderPrompt, monospaced: true, submit: save)
                }
                StandaloneField(title: HerdrProjectsCopy.projectNote, text: binding(\.note), prompt: HerdrProjectsCopy.projectNotePrompt, lines: 1...3)
                if !model.projectProblem.isEmpty {
                    Label(model.projectProblem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(draft.id == nil ? HerdrProjectsCopy.addProject : HerdrProjectsCopy.saveProject, action: save).disabled(!draft.isComplete || model.savingProject)
                    if canCancel { Button(HerdrProjectsCopy.cancel) { model.draft = nil } }
                    if model.savingProject { ProgressView().controlSize(.small) }
                }
            }.appleCard(padding: 16)
        }
    }

    private func binding(_ field: WritableKeyPath<HerdrProjectsModel.Draft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: field] ?? "" }, set: { model.draft?[keyPath: field] = $0 })
    }

    private func save() { Task { if let project = await model.saveProject() { saved(project) } } }
}

/// One project as a card: its name, where its folder is, and its note.
struct HerdrProjectCard<Trailing: View>: View {
    let project: HerdrProject
    var selected = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: "folder.fill", colour: AppColor.clay, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline)
                if !project.note.isEmpty { Text(project.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text("\(project.folder) on \(project.machine)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if project.reachable == false { Text("\(project.machine) is offline right now.").font(.caption).foregroundStyle(AppColor.caution) }
            }
            Spacer(minLength: 8)
            trailing()
        }.appleCard(padding: 12, selected: selected)
    }
}

/// Settings → Servers → Projects: the project servers of one Herdr server, adding one, and the
/// projects on them.
struct HerdrProjectsSection: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    var named = false
    /// Renders and tests show a state without a server.
    var preset: HerdrProjectsModel? = nil

    var body: some View {
        HerdrProjectsBody(model: preset ?? store.herdrProjectsModel(for: server), server: server, named: named)
    }
}

private struct HerdrProjectsBody: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrProjectsModel
    let server: HerdrServer
    let named: Bool
    @State private var addingServer = false
    @State private var removing: HerdrProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupHeading(title: named ? "\(HerdrProjectsCopy.title) for \(server.name)" : HerdrProjectsCopy.title, detail: HerdrProjectsCopy.intro(server.name))
            switch model.phase {
            case .idle: Button("Show projects") { Task { await load() } }
            case .reading: StatusCard(kind: .working, title: "Checking…")
            case .unavailable(let why): StatusCard(kind: .warning, title: "The projects could not be loaded", detail: why) { Button("Try again") { Task { await load() } }.padding(.top, 4) }
            case .ready: ready
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if model.phase == .idle, store.launchWorkEnabled { await load() } }
    }

    /// Each server your projects are on as one card with its projects inside, then a way to add a server, and one
    /// quiet line on what letting a bot use a project means.
    @ViewBuilder private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.machines) { HerdrMachineCard(model: model, machine: $0, listsProjects: true, removeProject: { removing = $0 }) }
            if model.machines.isEmpty || addingServer || model.adding != .fields {
                if model.machines.isEmpty { EmptyNote(symbol: "folder.badge.plus", title: "No projects yet", detail: "Add the server your code or files are on, then name the folders your bots may work in.") }
                HerdrAddMachineFlow(model: model, serverName: server.name).padding(.top, 8)
            } else {
                Button { addingServer = true } label: { Label("Add a server", systemImage: "plus") }.controlSize(.large)
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let project = removing { Task { if let catalog = await model.removeProject(project) { store.reconcileHerdrProjects(on: server, with: catalog) } } } }
        } message: { Text("No bot can use it any more. The folder itself is not touched.") }
        if !model.machines.isEmpty {
            Text("\(HerdrProjectsCopy.consequence) \(HerdrProjectsCopy.notIsolation)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        if let catalog = await model.load() { store.reconcileHerdrProjects(on: server, with: catalog) }
    }
}

/// Which projects a bot may use, as cards to switch on: in its settings and in its Details. The choice is saved at
/// once; a running agent gets the new list at once and is told with the next message.
struct HerdrBotProjectsSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var preset: HerdrProjectsModel? = nil
    /// Details shows nothing while the server has no project; the bot's settings say where to add one.
    var quietWhenEmpty = false

    var body: some View {
        HerdrBotProjectsBody(model: preset ?? store.herdrProjectsModel(for: store.herdrServer(for: bot)), bot: bot, quietWhenEmpty: quietWhenEmpty)
    }
}

private struct HerdrBotProjectsBody: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrProjectsModel
    @ObservedObject var bot: Bot
    let quietWhenEmpty: Bool
    @State private var note = ""
    @State private var editing = false

    var body: some View {
        let chosen = store.herdrProjects(for: bot), server = store.herdrServer(for: bot)
        Group {
            if model.projects.isEmpty && chosen.isEmpty {
                if !quietWhenEmpty {
                    SettingBlock(title: HerdrProjectsCopy.botTitle, detail: model.phase == .reading ? "Checking…" : HerdrProjectsCopy.botNone) { EmptyView() }
                }
            } else if quietWhenEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack {
                        Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if !model.projects.isEmpty {
                            Button(editing ? "Done" : "Edit") { editing.toggle() }
                                .buttonStyle(.link).accessibilityLabel(editing ? "Finish editing projects" : "Edit bot projects")
                        }
                    }
                    if editing {
                        choices(chosen)
                    } else if chosen.isEmpty {
                        Text("No projects selected").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(chosen) { kept in
                            let folder = model.projects.first { $0.id == kept.id }?.folder
                            let label = kept.machine + " · " + (folder ?? kept.name)
                            Text(verbatim: label).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(AppColor.selection, in: RoundedRectangle(cornerRadius: 4))
                                .help(label).accessibilityLabel(label)
                        }
                    }
                }
            } else {
                SettingBlock(title: HerdrProjectsCopy.botTitle, detail: HerdrProjectsCopy.consequence(bot.name)) {
                    choices(chosen)
                }
            }
        }
        // Only the real app reads on its own; a preview or test store shows what it was given.
        .task(id: server) {
            guard store.launchWorkEnabled else { return }
            if let catalog = await model.load() { store.reconcileHerdrProjects(on: server, with: catalog) }
        }
    }

    @ViewBuilder private func choices(_ chosen: [HerdrBotProject]) -> some View {
        ForEach(model.projects) { project in
            let on = chosen.contains { $0.id == project.id }
            HerdrProjectCard(project: project, selected: on) {
                Toggle("\(bot.name) may use \(project.name)", isOn: Binding(get: { on }, set: { set(project, $0) })).labelsHidden().toggleStyle(.appleSwitch).controlSize(.small)
                    .accessibilityLabel("\(bot.name) may use \(project.name)")
            }
        }
        // A project the server no longer lists stays visible until the list is read again.
        ForEach(chosen.filter { kept in !model.projects.contains { $0.id == kept.id } }) { kept in
            Text(kept.label).font(.callout).foregroundStyle(.secondary)
        }
        if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }

    private func set(_ project: HerdrProject, _ on: Bool) {
        var list = store.herdrProjects(for: bot).filter { $0.id != project.id }
        if on { list.append(HerdrBotProject(project)) }
        store.setHerdrProjects(list, for: bot)
        Task { note = await store.applyHerdrProjects(for: bot) }
    }
}

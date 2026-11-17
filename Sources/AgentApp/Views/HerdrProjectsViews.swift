import SwiftUI

// Project servers and projects of one Herdr server (`HerdrProjectsModel`): in Settings → Advanced → Servers and keys
// → Projects, in the setup wizard's optional step, and in a bot's settings and Details, where the person chooses
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

/// One project server as a card: its state, how it is reached, its projects, the workspace's own warnings, and
/// Connect again and Remove.
struct HerdrMachineCard: View {
    @ObservedObject var model: HerdrProjectsModel
    let machine: HerdrMachine
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: "externaldrive.connected.to.line.below.fill", colour: machine.reachable ? .teal : .gray, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(machine.name).font(.headline)
                        FactChip(text: machine.stateLine, symbol: machine.reachable ? "checkmark.circle.fill" : "exclamationmark.circle.fill", colour: machine.reachable ? .green : .orange)
                    }
                    Text(machine.target).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(machine.projects.isEmpty ? HerdrProjectsCopy.noProjects : "Projects: \(machine.projects.joined(separator: ", "))").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            ForEach(machine.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let said = model.said[machine.name] { Text(said).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Button("Connect again") { Task { await model.reconnect(machine) } }
                Button("Remove…", role: .destructive) { confirmRemove = true }
                if model.busy.contains(machine.name) { ProgressView().controlSize(.small) }
            }.disabled(model.busy.contains(machine.name))
        }
        .appleCard()
        .confirmationDialog("Remove \(machine.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.remove(machine) } }
        } message: { Text("Herdr forgets this server. Herdr's helper program stays on it, and so does anything it runs there.") }
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
                Text("\(project.folder) on \(project.machine)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !project.note.isEmpty { Text(project.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if project.reachable == false { Text("Its server is not connected now.").font(.caption).foregroundStyle(AppColor.caution) }
            }
            Spacer(minLength: 8)
            trailing()
        }.appleCard(padding: 12, selected: selected)
    }
}

/// Settings → Advanced → Servers and keys → Projects: the project servers of one Herdr server, adding one, and the
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
        VStack(alignment: .leading, spacing: 22) {
            GroupHeading(title: named ? "\(HerdrProjectsCopy.title) of \(server.name)" : HerdrProjectsCopy.title, detail: HerdrProjectsCopy.intro(server.name))
            switch model.phase {
            case .idle: Button("Read this server's project servers") { Task { await load() } }
            case .reading: StatusCard(kind: .working, title: "Reading this server's project servers…")
            case .unavailable(let why): StatusCard(kind: .warning, title: "The project servers could not be read", detail: why) { Button("Read again") { Task { await load() } }.padding(.top, 4) }
            case .ready: ready
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if model.phase == .idle, store.launchWorkEnabled { await load() } }
    }

    @ViewBuilder private var ready: some View {
        StatusCard(kind: .info, title: HerdrProjectsCopy.consequence, detail: HerdrProjectsCopy.notIsolation)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.machines) { HerdrMachineCard(model: model, machine: $0) }
            if model.machines.isEmpty || addingServer || model.adding != .fields {
                HerdrAddMachineFlow(model: model, serverName: server.name).padding(.top, model.machines.isEmpty ? 0 : 8)
            } else {
                Button("Add a project server…") { addingServer = true }
            }
        }
        if !model.machines.isEmpty {
            SettingBlock(title: HerdrProjectsCopy.projectsTitle, detail: HerdrProjectsCopy.projectsDetail) {
                ForEach(model.projects) { project in
                    HerdrProjectCard(project: project) {
                        Button("Change") { model.edit(project) }
                        Button(HerdrProjectsCopy.removeProject, role: .destructive) { removing = project }
                    }
                }
                if model.projects.isEmpty, model.draft == nil { Text(HerdrProjectsCopy.noProjects).font(.callout).foregroundStyle(.secondary) }
                if model.draft != nil { HerdrProjectEditor(model: model) }
                else {
                    if !model.projectProblem.isEmpty { Text(model.projectProblem).font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    Button("Add a project…") { model.newProject() }
                }
            }
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) { if let project = removing { Task { await model.removeProject(project); store.reconcileHerdrProjects(on: server, with: model.projects) } } }
            } message: { Text("The project leaves the list, and no bot can use it any more. The folder on the server is not touched.") }
        }
    }

    private func load() async {
        await model.load()
        if model.phase == .ready { store.reconcileHerdrProjects(on: server, with: model.projects) }
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

    var body: some View {
        let chosen = store.herdrProjects(for: bot), server = store.herdrServer(for: bot)
        Group {
            if model.projects.isEmpty && chosen.isEmpty {
                if !quietWhenEmpty {
                    SettingBlock(title: HerdrProjectsCopy.botTitle, detail: model.phase == .reading ? "Reading…" : HerdrProjectsCopy.botNone) { EmptyView() }
                }
            } else {
                SettingBlock(title: HerdrProjectsCopy.botTitle, detail: HerdrProjectsCopy.consequence(bot.name)) {
                    ForEach(model.projects) { project in
                        let on = chosen.contains { $0.id == project.id }
                        HerdrProjectCard(project: project, selected: on) {
                            Toggle("\(bot.name) may use \(project.name)", isOn: Binding(get: { on }, set: { set(project, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityLabel("\(bot.name) may use \(project.name)")
                        }
                    }
                    // A project the server no longer lists stays visible until the list is read again.
                    ForEach(chosen.filter { kept in !model.projects.contains { $0.id == kept.id } }) { kept in
                        if model.phase != .ready { Text(kept.label).font(.callout).foregroundStyle(.secondary) }
                    }
                    if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        // Only the real app reads on its own; a preview or test store shows what it was given.
        .task(id: server.id) {
            guard store.launchWorkEnabled else { return }
            await model.load()
            if model.phase == .ready { store.reconcileHerdrProjects(on: server, with: model.projects) }
        }
    }

    private func set(_ project: HerdrProject, _ on: Bool) {
        var list = store.herdrProjects(for: bot).filter { $0.id != project.id }
        if on { list.append(HerdrBotProject(project)) }
        store.setHerdrProjects(list, for: bot)
        Task { note = await store.applyHerdrProjects(for: bot) }
    }
}

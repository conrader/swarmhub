import SwiftUI

/// Settings → Servers → Skills, for each Herdr server: that server's library (`HerdrSkillsEntry`), or for a server
/// from before the library its list of switches (`HerdrSkillsModel`).
struct HerdrSkillsSection: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    /// With several servers the section says whose skills these are.
    var named = false
    /// Renders and tests show a state without a server: of the switch list an older server gets, or of the library.
    var preset: HerdrSkillsModel? = nil
    var library: HerdrLibraryModel? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupHeading(title: named ? "Skills on \(server.name)" : "Skills", detail: "What your bots know how to do. Every bot on \(server.name) gets what is in its library.")
            HerdrSkillsEntry(model: library ?? (preset == nil ? store.herdrLibraryModel(for: server) : .olderServer), legacy: preset ?? store.herdrSkillsModel(for: server), server: server)
        }
    }
}

/// A Herdr bot's Details → Skills: the library of the server the bot runs on. It is the server's, not the bot's
/// alone, and says so. When one of the bot's projects on that server has a library of its own, the panel offers the
/// choice between the two (`HerdrLibraryScopePicker`).
struct HerdrSkillsPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    /// Renders and tests show a state without a server: of the switch list, of the shared library, of a project's own.
    var preset: HerdrSkillsModel? = nil
    var library: HerdrLibraryModel? = nil
    var scoped: HerdrLibraryModel? = nil
    var body: some View {
        let server = store.herdrServer(for: bot)
        HerdrSkillsPanelBody(bot: bot, server: server, shared: library ?? (preset == nil ? store.herdrLibraryModel(for: server) : .olderServer),
                             legacy: preset ?? store.herdrSkillsModel(for: server), projects: store.herdrProjectsModel(for: server), scoped: scoped)
    }
}

private struct HerdrSkillsPanelBody: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let server: HerdrServer
    @ObservedObject var shared: HerdrLibraryModel
    @ObservedObject var legacy: HerdrSkillsModel
    @ObservedObject var projects: HerdrProjectsModel
    let scoped: HerdrLibraryModel?

    /// The bot's projects with where each is: the ones on the server itself may have a library of their own.
    private var candidates: [HerdrLibraryScope.Candidate] {
        let own = store.herdrProjects(for: bot).map(\.id)
        return projects.projects.filter { own.contains($0.id) }.map { project in
            let machine = projects.machines.first { $0.name == project.machine }
            return HerdrLibraryScope.Candidate(name: project.name, folder: project.folder, machineHost: machine?.host, machineTarget: machine?.target ?? "")
        }
    }

    var body: some View {
        let key = bot.id.uuidString, choices = shared.scopes[key] ?? []
        let chosen = store.herdrLibraryScope(for: bot).flatMap { folder in choices.first { $0.folder == folder } }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skills").font(.headline)
                Text(chosen.map { "What \(bot.name) knows how to do in \($0.name)." } ?? "What \(bot.name) knows how to do. All your bots on \(server.name) share these.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !choices.isEmpty {
                HerdrLibraryScopePicker(server: server, choices: choices, selection: chosen?.folder) { store.setHerdrLibraryScope($0, for: bot) }
            }
            if let chosen {
                HerdrSkillsEntry(model: scoped ?? store.herdrLibraryModel(for: server, project: chosen.folder), legacy: legacy, server: server, compact: true, scopeName: chosen.name).id(chosen.folder)
            } else {
                HerdrSkillsEntry(model: shared, legacy: legacy, server: server, compact: true)
            }
        }
        // The projects are read when nothing has read them yet; which of them hold a library is asked once both are known.
        .task(id: bot.id) { if projects.phase == .idle, store.launchWorkEnabled { await projects.load() } }
        .task(id: "\(shared.isOpen)|\(candidates.map(\.folder).joined(separator: "|"))") {
            if store.launchWorkEnabled { await shared.findScopes(for: key, among: candidates) }
        }
    }
}

/// The section's content: the server's own sentence when skillshare is missing or not set up; otherwise which agent
/// programs the library is shared with, a search field, one switch per skill, what the last switch and sync did, and
/// sharing with another agent program behind an explicit confirmation.
struct HerdrSkillsContent: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrSkillsModel
    let server: HerdrServer
    /// Settings keeps the list in a box of this height; nil lets it grow (the Details panel scrolls as a whole).
    let listHeight: CGFloat?
    @State private var showSharing = false
    @Environment(\.inspectorStartsAdvanced) private var renderOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle: Button("Show skills") { Task { await model.load() } }
            case .reading: StatusCard(kind: .working, title: "Checking…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The skills could not be loaded", detail: why) { Button("Try again") { Task { await model.load() } }.padding(.top, 4) }
            case .ready: if let library = model.library { ready(library) }
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if model.phase == .idle, store.launchWorkEnabled { await model.load() } }
    }

    @ViewBuilder private func ready(_ library: HerdrSkillLibrary) -> some View {
        if !library.installed || (library.skills.isEmpty && library.problem != nil) {
            // skillshare is missing or not set up: the server's sentence, not an empty list.
            StatusCard(kind: .warning, title: library.problem ?? "Skills are not set up on this server yet (skillshare is not installed there).") { Button("Try again") { Task { await model.load() } }.padding(.top, 4) }
        } else {
            if let problem = library.problem { StatusCard(kind: .warning, title: problem) }
            if !library.skills.isEmpty { Text("\(library.enabledCount) of \(library.skills.count) on").font(.callout.weight(.medium)).foregroundStyle(.secondary) }
            if library.skills.isEmpty {
                Text(HerdrSkillsCopy.empty).font(.callout).foregroundStyle(.secondary)
            } else {
                if library.skills.count > 8 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search skills", text: $model.query, prompt: Text("Search skills")).textFieldStyle(.plain).labelsHidden()
                    }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                let shown = library.matching(model.query)
                if shown.isEmpty { Text(HerdrSkillsCopy.noMatch(model.query)).foregroundStyle(.secondary) }
                else if let listHeight { ScrollView { rows(shown) }.frame(height: min(listHeight, CGFloat(shown.count) * 56)) }
                else { rows(shown) }
                if library.hiddenCount > 0 { Text(HerdrSkillsCopy.more(library.hiddenCount)).font(.caption).foregroundStyle(.secondary) }
            }
            status
            Text(HerdrSkillsCopy.runningAgents).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Which AIs get these skills, and sharing with another one: set once, by few people.
            QuietFold(title: "Advanced", isOpen: Binding(get: { showSharing || renderOpen || model.sharing != .closed }, set: { showSharing = $0 })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(library.sharedLine).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    sharing(library)
                }
            }
        }
    }

    /// The skills as one calm list on a single surface: a mark that is coloured while the skill is on, its name as
    /// people read it ("Code review" for `code-review`), what it does, and its switch.
    private func rows(_ skills: [HerdrSkillLibrary.Skill]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                let on = model.isOn(skill)
                if index > 0 { Divider().padding(.leading, 46) }
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 13)).foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 26, height: 26).background(on ? AnyShapeStyle(AppColor.sage.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HerdrSkillsCopy.readable(skill.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? .primary : .secondary)
                        if let description = skill.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(description)
                        }
                    }
                    Spacer(minLength: 8)
                    if model.isChanging(skill) { ProgressView().controlSize(.small) }
                    Toggle(skill.name, isOn: Binding(get: { on }, set: { model.set(skill, on: $0) })).labelsHidden().toggleStyle(.appleSwitch).controlSize(.small)
                        .accessibilityLabel(HerdrSkillsCopy.readable(skill.name))
                }.padding(.horizontal, 10).padding(.vertical, 8).help(skill.name)
            }
        }
        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
    }

    /// What the last switch and sync did; or that the agent programs are behind, with the way to bring them over.
    @ViewBuilder private var status: some View {
        if model.syncing {
            StatusCard(kind: .working, title: "Updating your bots…")
        } else if let behind = model.behind {
            switch behind {
            case .waiting: StatusCard(kind: .warning, title: HerdrSkillsCopy.notUpToDate) { Button("Update now") { Task { await model.sync() } }.padding(.top, 4) }
            case .failed(let line): StatusCard(kind: .warning, title: "Your bots could not be updated", detail: line) { Button("Try again") { Task { await model.sync() } }.padding(.top, 4) }
            }
        } else if !model.note.isEmpty {
            Text(model.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sharing with another agent program. The server is asked what it finds only when this is opened, and a program
    /// is added only after a confirmation that says what that means.
    @ViewBuilder private func sharing(_ library: HerdrSkillLibrary) -> some View {
        switch model.sharing {
        case .closed:
            HStack {
                Button("Share with another AI…") { Task { await model.openSharing() } }.disabled(model.isBusy)
                Spacer()
                Button("Refresh") { Task { await model.load() } }.disabled(model.isBusy)
            }
        case .asking: StatusCard(kind: .working, title: "Checking \(server.name)…")
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Close") { model.closeSharing() }
        case .offered(let agents):
            if let agent = model.confirming {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HerdrSkillsCopy.shareTitle(agent)).font(.headline)
                    Text(HerdrSkillsCopy.shareConsequence(agent, server: server.name, count: library.enabledCount)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.confirming = nil }.keyboardShortcut(.cancelAction)
                        Button("Share with \(agent)") { Task { await model.share(with: agent) } }.buttonStyle(.appleProminent).disabled(model.adding)
                    }
                }.appleCard(padding: 14)
            } else if agents.isEmpty {
                Text(HerdrSkillsCopy.nothingToShare).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Close") { model.closeSharing() }
            } else {
                HStack {
                    ForEach(agents, id: \.self) { agent in Button("Share with \(agent)…") { model.confirming = agent } }
                    Spacer()
                    Button("Close") { model.closeSharing() }
                }
            }
        }
    }
}

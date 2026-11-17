import SwiftUI

/// Settings → Advanced → Servers and keys, under each Herdr server: that server's skill library (`HerdrSkillsModel`).
struct HerdrSkillsSection: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    /// With several servers the section says whose skills these are.
    var named = false
    /// Renders and tests show a state without a server.
    var preset: HerdrSkillsModel? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupHeading(title: named ? "Skills on \(server.name)" : "Skills", detail: "What the agents on \(server.name) know how to do. Turn a skill off to keep it from every agent there.")
            HerdrSkillsContent(model: preset ?? store.herdrSkillsModel(for: server), server: server, listHeight: nil)
        }
    }
}

/// A Herdr bot's Details → Skills: the skill library of the server the bot runs on. It is the server's, not the
/// bot's alone, and says so.
struct HerdrSkillsPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var preset: HerdrSkillsModel? = nil
    var body: some View {
        let server = store.herdrServer(for: bot)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: "puzzlepiece.extension.fill", colour: AppColor.sage, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skills on \(server.name)").font(.headline)
                    Text("These belong to \(server.name), not to \(bot.name) alone: every bot there whose agent program the library is shared with gets the ones that are on.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HerdrSkillsContent(model: preset ?? store.herdrSkillsModel(for: server), server: server, listHeight: nil)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle: Button("Read this server's skills") { Task { await model.load() } }
            case .reading: StatusCard(kind: .working, title: "Reading this server's skills…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The skills could not be read", detail: why) { Button("Read again") { Task { await model.load() } }.padding(.top, 4) }
            case .ready: if let library = model.library { ready(library) }
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if model.phase == .idle, store.launchWorkEnabled { await model.load() } }
    }

    @ViewBuilder private func ready(_ library: HerdrSkillLibrary) -> some View {
        if !library.installed || (library.skills.isEmpty && library.problem != nil) {
            // skillshare is missing or not set up: the server's sentence, not an empty list.
            StatusCard(kind: .warning, title: library.problem ?? "skillshare is not installed on this server.") { Button("Read again") { Task { await model.load() } }.padding(.top, 4) }
        } else {
            if let problem = library.problem { StatusCard(kind: .warning, title: problem) }
            Text("\(library.enabledCount) of \(HerdrSkillLibrary.skills(library.skills.count)) on. \(library.sharedLine)").font(.callout).fixedSize(horizontal: false, vertical: true)
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
                else if let listHeight { ScrollView { rows(shown) }.frame(height: min(listHeight, CGFloat(shown.count) * 64)) }
                else { rows(shown) }
                if library.hiddenCount > 0 { Text(HerdrSkillsCopy.more(library.hiddenCount)).font(.caption).foregroundStyle(.secondary) }
            }
            status
            Text(HerdrSkillsCopy.runningAgents).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sharing(library)
        }
    }

    /// Each skill is a card of its own: its name, what it does, and its switch beside them.
    private func rows(_ skills: [HerdrSkillLibrary.Skill]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(skills) { skill in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(.system(size: 13, weight: .semibold))
                        if let description = skill.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(description)
                        }
                    }
                    Spacer(minLength: 8)
                    if model.isChanging(skill) { ProgressView().controlSize(.small) }
                    Toggle(skill.name, isOn: Binding(get: { model.isOn(skill) }, set: { model.set(skill, on: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel(skill.name)
                }.appleCard(padding: 10).opacity(model.isOn(skill) ? 1 : 0.7)
            }
        }
    }

    /// What the last switch and sync did; or that the agent programs are behind, with the way to bring them over.
    @ViewBuilder private var status: some View {
        if model.syncing {
            StatusCard(kind: .working, title: "Updating the agent programs…")
        } else if let behind = model.behind {
            switch behind {
            case .waiting: StatusCard(kind: .warning, title: HerdrSkillsCopy.notUpToDate) { Button("Update now") { Task { await model.sync() } }.padding(.top, 4) }
            case .failed(let line): StatusCard(kind: .warning, title: "Not updated", detail: line) { Button("Retry") { Task { await model.sync() } }.padding(.top, 4) }
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
                Button("Share with another agent program…") { Task { await model.openSharing() } }.disabled(model.isBusy)
                Spacer()
                Button("Read again") { Task { await model.load() } }.disabled(model.isBusy)
            }
        case .asking: StatusCard(kind: .working, title: "Asking \(server.name) which agent programs it finds…")
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
                        Button("Share with \(agent)") { Task { await model.share(with: agent) } }.buttonStyle(.borderedProminent).disabled(model.adding)
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

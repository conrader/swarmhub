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
        Section(named ? "Skills on \(server.name)" : "Skills") {
            HerdrSkillsContent(model: preset ?? store.herdrSkillsModel(for: server), server: server, listHeight: 300)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills on \(server.name)").font(.headline)
            Text("These belong to \(server.name), not to \(bot.name) alone: every bot there whose agent program the library is shared with gets the ones that are on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        Group {
            switch model.phase {
            case .idle: Button("Read this server's skills") { Task { await model.load() } }
            case .reading: HStack { ProgressView().controlSize(.small); Text("Reading this server's skills…").foregroundStyle(.secondary) }
            case .unavailable(let why):
                Text(why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Read again") { Task { await model.load() } }
            case .ready: if let library = model.library { ready(library) }
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if model.phase == .idle, store.launchWorkEnabled { await model.load() } }
    }

    @ViewBuilder private func ready(_ library: HerdrSkillLibrary) -> some View {
        if !library.installed || (library.skills.isEmpty && library.problem != nil) {
            // skillshare is missing or not set up: the server's sentence, not an empty list.
            Label(library.problem ?? "skillshare is not installed on this server.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button("Read again") { Task { await model.load() } }
        } else {
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("\(library.enabledCount) of \(HerdrSkillLibrary.skills(library.skills.count)) on. \(library.sharedLine)").fixedSize(horizontal: false, vertical: true)
            if library.skills.isEmpty {
                Text(HerdrSkillsCopy.empty).font(.caption).foregroundStyle(.secondary)
            } else {
                if library.skills.count > 8 { TextField("Search skills", text: $model.query, prompt: Text("Search skills")).textFieldStyle(.roundedBorder).labelsHidden() }
                let shown = library.matching(model.query)
                if shown.isEmpty { Text(HerdrSkillsCopy.noMatch(model.query)).foregroundStyle(.secondary) }
                else if let listHeight { ScrollView { rows(shown) }.frame(height: min(listHeight, CGFloat(shown.count) * 52)) }
                else { rows(shown) }
                if library.hiddenCount > 0 { Text(HerdrSkillsCopy.more(library.hiddenCount)).font(.caption).foregroundStyle(.secondary) }
            }
            status
            Text(HerdrSkillsCopy.runningAgents).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sharing(library)
        }
    }

    private func rows(_ skills: [HerdrSkillLibrary.Skill]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(skills) { skill in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                        if let description = skill.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(description)
                        }
                    }
                    Spacer(minLength: 8)
                    if model.isChanging(skill) { ProgressView().controlSize(.small) }
                    Toggle(skill.name, isOn: Binding(get: { model.isOn(skill) }, set: { model.set(skill, on: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel(skill.name)
                }.padding(.vertical, 6)
                if skill.id != skills.last?.id { Divider() }
            }
        }
    }

    /// What the last switch and sync did; or that the agent programs are behind, with the way to bring them over.
    @ViewBuilder private var status: some View {
        if model.syncing {
            HStack { ProgressView().controlSize(.small); Text("Updating the agent programs…").foregroundStyle(.secondary) }
        } else if let behind = model.behind {
            HStack(alignment: .top) {
                switch behind {
                case .waiting:
                    Label(HerdrSkillsCopy.notUpToDate, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Update now") { Task { await model.sync() } }
                case .failed(let line):
                    Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await model.sync() } }
                }
            }
        } else if !model.note.isEmpty {
            Text(model.note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
        case .asking: HStack { ProgressView().controlSize(.small); Text("Asking \(server.name) which agent programs it finds…").foregroundStyle(.secondary) }
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
                        Button("Share with \(agent)") { Task { await model.share(with: agent) } }.disabled(model.adding)
                    }
                }.padding(12).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
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

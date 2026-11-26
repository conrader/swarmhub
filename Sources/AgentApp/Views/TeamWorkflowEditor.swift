import SwiftUI

struct TeamWorkflowEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: GroupChat
    let bot: Bot
    @State private var draft: TeamWorkflow<UUID>
    private let original: TeamWorkflow<UUID>
    @State private var choosingSkill = false
    @State private var error: String?

    init(group: GroupChat, bot: Bot) {
        self.group = group
        self.bot = bot
        original = group.workflows[bot.id] ?? .init()
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skills & handoffs").font(.title3.weight(.semibold))
            Text(bot.name + " in " + group.name).foregroundStyle(.secondary)
            if choosingSkill {
                WorkspaceSkillPicker(server: store.herdrServer(for: bot)) { skill in
                    draft.skills.append(skill)
                    choosingSkill = false
                }
                Spacer()
                Button("Back") { choosingSkill = false }.keyboardShortcut(.cancelAction)
            } else {
                editor
            }
        }.padding(20).frame(width: 470, height: 440).background(AppColor.panel)
    }

    @ViewBuilder private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Skills").font(.headline)
                ForEach(draft.skills.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Skill name", text: $draft.skills[index].name)
                            Button("Remove") { draft.skills.remove(at: index) }.accessibilityLabel("Remove skill " + draft.skills[index].name)
                        }
                        TextField("Instructions for this skill", text: $draft.skills[index].instructions, axis: .vertical).lineLimit(2...8)
                    }
                }
                HStack {
                    Button("Add skill") { draft.skills.append(.init(name: "", instructions: "")) }
                    if bot.backend == .herdr {
                        Button("From workspace…") { choosingSkill = true }
                    }
                }
                Divider().padding(.vertical, 4)
                Text("Handoff rules").font(.headline)
                let peers = store.members(of: group).filter { $0.id != bot.id }
                ForEach(draft.handoffs.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        HStack {
                            Picker("Hand off to", selection: $draft.handoffs[index].recipient) {
                                ForEach(peers) { Text($0.name).tag($0.id) }
                            }
                            Button("Remove") { draft.handoffs.remove(at: index) }.accessibilityLabel("Remove handoff rule")
                        }
                        TextField("When should this member take over?", text: $draft.handoffs[index].condition, axis: .vertical)
                            .lineLimit(1...5)
                    }
                }
                Button("Add handoff rule") {
                    if let peer = peers.first { draft.handoffs.append(.init(recipient: peer.id, condition: "")) }
                }.disabled(peers.isEmpty)
            }.textFieldStyle(.roundedBorder).padding(3)
        }
        if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft == original)
        }
    }

    private func save() {
        do {
            guard store.groups.contains(where: { $0 === group }), group.memberIDs.contains(bot.id),
                  (group.workflows[bot.id] ?? .init()) == original else {
                throw BackendError.unavailable("The team changed while this editor was open. Reopen it to edit the latest workflow.")
            }
            try draft.validate(owner: bot.id, members: group.memberIDs)
            let previous = group.workflows[bot.id]
            group.workflows[bot.id] = draft.isEmpty ? nil : draft
            do { try store.writeStore() }
            catch { group.workflows[bot.id] = previous; throw error }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct WorkspaceSkillPicker: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let add: (TeamSkill) -> Void
    @State private var skills: [HerdrClient.WorkspaceSkill]?
    @State private var selected: Int?
    @State private var problem: String?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills on " + server.name).font(.headline)
            if let problem {
                Text(problem)
                Button("Retry") { attempt += 1 }
            } else if let skills {
                if skills.isEmpty { Text("No saved skills on this workspace.") }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(skills) { skill in
                            Button(skill.name) { selected = skill.id }.disabled(selected != nil)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ProgressView() }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attempt) {
            problem = nil
            do { skills = try await store.herdrClient(for: server).workspaceSkills().filter { !$0.archived } }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
        .task(id: selected) {
            guard let selected else { return }
            do {
                let skill = try await store.herdrClient(for: server).workspaceSkill(selected)
                try Task.checkCancellation()
                guard !skill.archived, let text = skill.instructions else { throw BackendError.unavailable("This skill is unavailable.") }
                add(.init(name: skill.name, instructions: text))
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription; self.selected = nil }
            }
        }
    }
}

import SwiftUI

/// Right panel for a group: rename, members with avatar/name/profile, add from existing bots, remove.
struct GroupInfoPanel: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Members").font(.system(size: 14, weight: .semibold)); Spacer()
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(.plain).help("Close")
            }.padding(.horizontal, 14).frame(height: 54)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView { content.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(AppColor.panel)
            .onAppear { name = group.name }.onChange(of: group.id) { _, _ in name = group.name }
    }

    private var content: some View {
        let members = store.members(of: group)
        let candidates = store.bots.filter { !group.memberIDs.contains($0.id) && !$0.isReadOnlyArchive && !$0.isDemo }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Group name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField("Group name", text: $name).textFieldStyle(.roundedBorder).onSubmit { store.renameGroup(group, to: name) }
                    Button("Rename") { store.renameGroup(group, to: name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == group.name)
                }
            }
            Text("\(members.count + 1) in this chat").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading) { Text(GroupRouting.userName); Text("Owner").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(members) { bot in
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 30, motion: .list, isWorking: store.isWorking(bot, in: group))
                    VStack(alignment: .leading) { Text(bot.name); Text(profileLabel(bot)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { store.removeMember(bot.id, from: group) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove \(bot.name) from the group").disabled(store.streamingConversation === group)
                }
            }
            Menu {
                ForEach(candidates) { bot in Button(bot.name) { store.addMember(bot, to: group) } }
            } label: { Label("Add bot", systemImage: "plus") }.disabled(candidates.isEmpty).fixedSize()
            Text("Without an @mention a message goes to every member, one after another. Each bot keeps its own session for this group.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func profileLabel(_ bot: Bot) -> String {
        bot.backend == .hermes ? "Hermes · \(bot.hermesProfile ?? "default")" : bot.backend.rawValue
    }
}

/// "New group": a name (optional) and at least two existing bots.
struct NewGroupSheet: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    var preselected: Set<UUID> = []
    @State private var name = ""; @State private var picked: Set<UUID> = []

    var body: some View {
        let bots = store.bots.filter { !$0.isReadOnlyArchive && (!$0.isDemo || picked.contains($0.id)) }
        VStack(alignment: .leading, spacing: 12) {
            Text("New group").font(.title3.weight(.semibold))
            TextField(picked.count >= 2 ? store.defaultGroupName(ordered(bots)) : "Group name (optional)", text: $name).textFieldStyle(.roundedBorder)
            Text("Pick at least two bots").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bots) { bot in
                        Toggle(isOn: Binding(get: { picked.contains(bot.id) }, set: { if $0 { picked.insert(bot.id) } else { picked.remove(bot.id) } })) {
                            HStack(spacing: 8) { BotAvatar(bot: bot, size: 22, motion: .list, isWorking: store.isWorking(bot)); Text(bot.name) }
                        }.toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { if store.createGroup(name: name, memberIDs: ordered(bots)) != nil { dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(picked.count < 2)
            }
        }.padding(20).frame(width: 380).background(AppColor.panel)
            .onAppear { picked = preselected }
    }

    /// Member order follows the sidebar order of the picked bots.
    private func ordered(_ bots: [Bot]) -> [UUID] { bots.map(\.id).filter(picked.contains) }
}

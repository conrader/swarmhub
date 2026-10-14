import SwiftUI

/// "New group": a name (optional) and at least two existing bots.
struct NewGroupSheet: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    var preselected: Set<UUID> = []
    @State private var name = ""; @State private var picked: Set<UUID> = []

    var body: some View {
        let bots = store.bots.filter { !$0.isReadOnlyArchive && $0.joinsGroups && (!$0.isDemo || picked.contains($0.id)) }
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

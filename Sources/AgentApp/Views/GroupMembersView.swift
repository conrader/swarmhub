import SwiftUI

/// Right panel for a group (P21b item 3): its name, the members with avatar and name, Remove, Add agent and a mute
/// switch on top; who answers, @mentions, the context cap and where each member runs fold under Advanced
/// (`GroupRoutingDetails`). Same store calls as before: nothing about routing changes.
struct GroupInfoPanel: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(InspectorCopy.members).font(.system(size: 14, weight: .semibold)); Spacer()
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.buttonStyle(.plain).help(InspectorCopy.close)
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
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
                Text(InspectorCopy.groupName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    TextField(InspectorCopy.groupName, text: $name).textFieldStyle(.roundedBorder).onSubmit { store.renameGroup(group, to: name) }
                    Button(InspectorCopy.rename) { store.renameGroup(group, to: name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == group.name)
                }
            }
            Text(InspectorCopy.inThisChat(members.count + 1)).font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                VStack(alignment: .leading) { Text(store.userName); Text(InspectorCopy.owner).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(members) { bot in
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 30, motion: .list, isWorking: store.isWorking(bot, in: group), facing: .left,
                              isWaiting: store.hasPendingApproval(bot, in: group))
                    Text(bot.name)
                    Spacer()
                    Button(InspectorCopy.remove) { store.removeMember(bot.id, from: group) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help(InspectorCopy.removeHelp(bot.name)).disabled(store.streamingConversation === group)
                }
            }
            Menu {
                ForEach(candidates) { bot in Button(bot.name) { store.addMember(bot, to: group) } }
            } label: { Label(InspectorCopy.addAgent, systemImage: "plus") }.disabled(candidates.isEmpty).fixedSize()
            Toggle(InspectorCopy.mute, isOn: Binding(get: { group.isMuted }, set: { group.isMuted = $0; store.save() })).toggleStyle(.switch).controlSize(.small)
            AdvancedFold { GroupRoutingDetails(members: members) }
        }
    }
}

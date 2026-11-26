import SwiftUI
import UniformTypeIdentifiers

/// Right panel for a group (P21b item 3): its name, the members with avatar and name, Remove, Add agent and a mute
/// switch on top; who answers, @mentions, the context cap and where each member runs fold under Advanced
/// (`GroupRoutingDetails`). Same store calls as before: nothing about routing changes.
struct GroupInfoPanel: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var group: GroupChat
    @State private var name = ""
    @State private var workflowBot: Bot?
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(InspectorCopy.members).font(.system(size: 14, weight: .semibold)); Spacer()
                if let bot = store.members(of: group).first(where: { $0.backend == .herdr }) {
                    Button("Terminal", systemImage: "terminal") {
                        store.previewInInspector(.init(server: store.herdrServer(for: bot), groupID: group.id))
                    }.controlSize(.small).accessibilityLabel("Show group terminals in Details")
                }
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(InspectorCopy.close).accessibilityLabel(InspectorCopy.close)
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView { content.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: ChromeMetrics.infoWidth.min, idealWidth: ChromeMetrics.infoWidth.ideal, maxWidth: ChromeMetrics.infoWidth.max).background(AppColor.panel)
            .onAppear { name = group.name }.onChange(of: group.id) { _, _ in name = group.name }
    }

    private var content: some View {
        let members = store.members(of: group)
        let candidates = store.groupCandidates().filter { !group.memberIDs.contains($0.id) }
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
                    BotAvatar(bot: bot, size: 30, motion: .list, isWorking: store.isWorking(bot, in: group), facing: .left)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bot.name)
                        Button("Skills & handoffs…") { workflowBot = bot }
                            .buttonStyle(.link).font(.caption).accessibilityLabel("Skills and handoffs for " + bot.name)
                    }
                    Spacer()
                    Button(InspectorCopy.remove) { store.removeMember(bot.id, from: group) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help(InspectorCopy.removeHelp(bot.name)).disabled(!store.isIdle(group))
                }
            }
            Menu {
                ForEach(candidates) { bot in Button(bot.name) { store.addMember(bot, to: group) } }
            } label: { Label(InspectorCopy.addAgent, systemImage: "plus") }.disabled(candidates.isEmpty).fixedSize()
            Toggle(InspectorCopy.mute, isOn: Binding(get: { group.isMuted }, set: { group.isMuted = $0; store.save() })).toggleStyle(.appleSwitchLabelled).controlSize(.small)
            Button("Export Team Pack…", action: exportTeamPack).disabled(members.count < 2)
            if let exportError { Text(exportError).font(.callout).foregroundStyle(.secondary) }
            AdvancedFold { GroupRoutingDetails(members: members) }
        }.sheet(item: $workflowBot) { bot in TeamWorkflowEditor(group: group, bot: bot) }
    }

    private func exportTeamPack() {
        exportError = nil
        do {
            let data = try TeamPack(group: group, store: store).encoded()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SwarmHub Team Pack.json"
            panel.message = "Share this group’s bot names, roles, instructions, skills, handoff rules, avatars and model choices."
            panel.begin { answer in
                guard answer == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) }
                catch { exportError = error.localizedDescription }
            }
        } catch { exportError = error.localizedDescription }
    }
}

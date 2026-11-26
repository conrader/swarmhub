import SwiftUI
import UniformTypeIdentifiers

/// "New group": a name (optional) and at least two existing bots.
struct NewGroupSheet: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    var preselected: Set<UUID> = []
    @State private var name = ""; @State private var picked: Set<UUID> = []

    @State private var pack: TeamPack?
    @State private var packError: String?
    @State private var serverID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pack { review(pack) } else { groupForm }
            if let packError { Text(packError).font(.callout).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 420).background(AppColor.panel)
            .onAppear { picked = preselected }
    }

    private func choosePack() {
        packError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { answer in
            guard answer == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { pack = try TeamPack.read(url) }
            catch { packError = error.localizedDescription }
        }
    }

    private var groupForm: some View {
        let bots = store.groupCandidates(including: picked)
        return VStack(alignment: .leading, spacing: 12) {
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
                Button("Import Team Pack…", action: choosePack)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { if store.createGroup(name: name, memberIDs: ordered(bots)) != nil { dismiss() } }
                    .buttonStyle(.appleProminent).disabled(picked.count < 2)
            }
        }
    }

    private func review(_ pack: TeamPack) -> some View {
        let servers = store.herdrServers
        let server = servers.first { $0.id == serverID } ?? servers[0]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Import Team Pack").font(.title3.weight(.semibold))
            Text(pack.name).font(.headline)
            Text("Creates a group and \(pack.members.count) new bots. Each bot starts with an empty chat and the destination workspace’s permissions.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Workspace", selection: Binding(get: { server.id }, set: { serverID = $0 })) {
                ForEach(servers) { Text($0.name).tag($0.id) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pack.members.indices, id: \.self) { index in
                        let member = pack.members[index]
                        DisclosureGroup(member.name) {
                            VStack(alignment: .leading, spacing: 4) {
                                if !member.title.isEmpty { Text(member.title).font(.headline) }
                                if !member.description.isEmpty { Text(member.description) }
                                if let template = member.template { Text(template).font(.caption) }
                                if let model = member.model, !model.isEmpty {
                                    Text(model == HerdrModelChoice.recommended ? "Recommended model" : model).font(.caption)
                                }
                                Text(member.instructions).textSelection(.enabled)
                                if let workflow = member.workflow {
                                    ForEach(workflow.skills.indices, id: \.self) { index in
                                        Text(workflow.skills[index].name).font(.headline)
                                        Text(workflow.skills[index].instructions).textSelection(.enabled)
                                    }
                                    ForEach(workflow.handoffs.indices, id: \.self) { index in
                                        let rule = workflow.handoffs[index]
                                        Text("Hand off to " + pack.members[rule.recipient].name).font(.headline)
                                        Text(rule.condition).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(4)
            }.frame(minHeight: 130, idealHeight: 200, maxHeight: 230)
            HStack {
                Button("Back") { self.pack = nil; packError = nil }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import group") {
                    do { try store.importTeamPack(pack, on: server); dismiss() }
                    catch { packError = error.localizedDescription }
                }.buttonStyle(.appleProminent)
            }
        }
    }

    /// Member order follows the sidebar order of the picked bots.
    private func ordered(_ bots: [Bot]) -> [UUID] { bots.map(\.id).filter(picked.contains) }
}

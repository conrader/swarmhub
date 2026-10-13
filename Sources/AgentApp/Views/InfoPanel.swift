import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var tab = PanelTab.overview

    private enum PanelTab: String, CaseIterable { case overview = "Overview", routines = "Routines", media = "Media", computer = "Computer", members = "Members" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }.buttonStyle(.plain).help("Bot settings")
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close")
            }.padding(.horizontal, 14).frame(height: 54)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            HStack(spacing: 3) { ForEach(PanelTab.allCases, id: \.self) { item in Button(item.rawValue) { tab = item }.font(.system(size: 10, weight: tab == item ? .semibold : .regular)).buttonStyle(.plain).padding(.horizontal, 6).frame(height: 26).background(tab == item ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6)) } }.padding(8)
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(AppColor.panel)
    }

    @ViewBuilder private var panelContent: some View {
        switch tab {
        case .overview:
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) { BotAvatar(bot: bot, size: 52, motion: .focus, isWorking: store.isWorking(bot), probe: "overview"); VStack(alignment: .leading) { Text(bot.name).font(.headline); Text(bot.title).foregroundStyle(.secondary) } }
                Text(bot.botDescription.isEmpty ? "No description yet." : bot.botDescription).foregroundStyle(.secondary)
                infoSection("Memory", text: bot.memorySummary.isEmpty ? "Memory will appear as this bot learns your preferences." : bot.memorySummary)
                BotCapabilitiesView(bot: bot, cache: store.botInfo)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Approval policy").font(.headline); Spacer(); Text(bot.approvalMode.rawValue).font(.caption).foregroundStyle(.secondary) }
                    ForEach(bot.approvalAudit.suffix(20).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(entry.actionKind).font(.caption.weight(.semibold)); Spacer(); Text(entry.outcome.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                            Text("\(entry.decidedBy) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                        }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if bot.approvalAudit.isEmpty { Text("Approval requests and decisions will appear here. Command text and arguments are not stored in this audit.").font(.caption).foregroundStyle(.secondary) }
                }
                if bot.backend == .hermes {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delegated tasks").font(.headline)
                        ForEach(store.subAgentTasks[bot.id] ?? []) { task in HStack { Image(systemName: task.status == .completed ? "checkmark.circle" : "person.2"); VStack(alignment: .leading) { Text(task.title).font(.caption.weight(.medium)); Text(task.detail).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Text(task.status.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary) }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8)) }
                        if (store.subAgentTasks[bot.id] ?? []).isEmpty { Text("Delegated work will appear here while Hermes runs sub-agents.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        case .routines:
            RoutinesView(bot: bot, cache: store.routines)
        case .media:
            MediaTabView(bot: bot)
        case .computer:
            ComputerTab(bot: bot)
        case .members:
            VStack(alignment: .leading, spacing: 12) {
                Text("Members").font(.headline); member(GroupRouting.userName, role: "Owner"); member(bot.name, role: "Agent")
                let groups = store.groups.filter { $0.memberIDs.contains(bot.id) }
                if !groups.isEmpty {
                    Text("Groups").font(.headline).padding(.top, 6)
                    ForEach(groups) { group in Button { store.open(group) } label: { Label(group.name, systemImage: "person.3") }.buttonStyle(.plain) }
                }
                Button("New group with \(bot.name)…") { store.showingNewGroup = true }.disabled(bot.isReadOnlyArchive)
            }
        }
    }
    private func infoSection(_ title: String, text: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).lineSpacing(2) } }
    private func member(_ name: String, role: String) -> some View { HStack { Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(name); Text(role).font(.caption).foregroundStyle(.secondary) } } }
}


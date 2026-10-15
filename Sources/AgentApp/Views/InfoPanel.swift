import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }.buttonStyle(.plain).help(SimpleCopy.agentSettings)
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close")
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            InfoTabBar(tabs: store.infoTabs(for: bot), selection: store.visibleInfoTab(for: bot)) { store.infoTab = $0 }
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(AppColor.panel)
        // Runs when the panel appears and when the chat's session id changes (the first send creates it); the cache
        // decides whether the entry is stale. Never polls. Feeds Overview's model line and pointers, Model and Skills.
        .task(id: "\(bot.id)|\(bot.hermesSessionID ?? "")") { if store.botInfo.autoLoad { await store.loadServerInfo(for: bot) } }
    }

    /// P17: the model section reads any agent's own catalog (or its reason).
    private var hasModel: Bool { [.hermes, .openClaw].contains(bot.backend) && !bot.isReadOnlyArchive }

    @ViewBuilder private var panelContent: some View {
        switch store.visibleInfoTab(for: bot) {
        case .overview: overview
        case .model:
            if hasModel { ModelSectionView(bot: bot, cache: store.botInfo) } else { Text("This agent has no model to show.").foregroundStyle(.secondary) }
        case .skills: BotCapabilitiesView(bot: bot, cache: store.botInfo)
        case .activity:
            VStack(alignment: .leading, spacing: 18) {
                if bot.backend == .hermes && !bot.isReadOnlyArchive { BotUsageView(bot: bot) }
                ApprovalAuditSection(bot: bot)
                if bot.backend == .hermes {
                    BotMessagesSection(bot: bot, center: store.botMessages)
                    DelegatedTasksSection(bot: bot, events: store.subAgentTasks[bot.id] ?? [])
                }
            }
        case .routines: RoutinesView(bot: bot, cache: store.routines)
        case .media: MediaTabView(bot: bot)
        case .computer: ComputerTab(bot: bot)
        }
    }

    /// P33: identity, description, one model line, memory (or the OpenClaw status), pointers to tabs that need
    /// attention, then what the Members tab held.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) { BotAvatar(bot: bot, size: 52, motion: .focus, isWorking: store.isWorking(bot), probe: "overview", facing: .left,
                                          isWaiting: store.hasPendingApproval(bot)); VStack(alignment: .leading) { Text(bot.name).font(.headline); Text(bot.title).foregroundStyle(.secondary); HermesVersionCaption(bot: bot, cache: store.botInfo) } }
            Text(bot.botDescription.isEmpty ? "No description yet." : bot.botDescription).foregroundStyle(.secondary)
            if hasModel { ModelSectionView(bot: bot, cache: store.botInfo, compact: true) }
            if bot.backend == .openClaw {
                OpenClawOverviewSection(status: store.openClawStatus, bot: bot)
            } else {
                MemorySection(bot: bot)
            }
            InfoPointerRows(pointers: store.infoPointers(for: bot))
            members
        }
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Members").font(.headline); member(store.userName, role: "Owner"); member(bot.name, role: "Agent")
            let groups = store.groups.filter { $0.memberIDs.contains(bot.id) }
            if !groups.isEmpty {
                Text("Groups").font(.headline).padding(.top, 6)
                ForEach(groups) { group in Button { store.open(group) } label: { Label(group.name, systemImage: "person.3") }.buttonStyle(.plain) }
            }
            Button("New group with \(bot.name)…") { store.showingNewGroup = true }.disabled(bot.isReadOnlyArchive)
        }
    }
    private func member(_ name: String, role: String) -> some View { HStack { Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(name); Text(role).font(.caption).foregroundStyle(.secondary) } } }
}

/// The bot's Hermes version, small, under its name in the Overview header (P24); nothing until it has been read.
private struct HermesVersionCaption: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: BotInfoCache
    var body: some View {
        if bot.backend == .hermes, !bot.isReadOnlyArchive, let reading = store.hermesVersion(for: bot) {
            Text(reading.label).font(.caption2).foregroundStyle(.secondary).help(reading.problem ?? "Hermes version reported by this agent's server")
        }
    }
}

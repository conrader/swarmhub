import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Details").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.editingBot = bot } label: { Image(systemName: "gearshape").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(SimpleCopy.agentSettings).accessibilityLabel(SimpleCopy.agentSettings)
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }.padding(.horizontal, 14).frame(height: 54).windowDragStrip(probe: "details_header")
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            InfoTabBar(tabs: store.infoTabs(for: bot), selection: store.visibleInfoTab(for: bot)) { store.infoTab = $0 }
            Rectangle().fill(AppColor.separator).frame(height: 0.5)
            ScrollView { panelContent.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).background(AppColor.panel)
    }

    @ViewBuilder private var panelContent: some View {
        switch store.visibleInfoTab(for: bot) {
        case .overview: overview
        case .model: VStack(alignment: .leading, spacing: 12) { HerdrAgentControls(bot: bot) }
        case .media: MediaTabView(bot: bot)
        }
    }

    /// Identity, description, where the agent runs and its helpers, then the members.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) { BotAvatar(bot: bot, size: 52, motion: .focus, isWorking: store.isWorking(bot), probe: "overview", facing: .left); VStack(alignment: .leading) { HStack(spacing: 6) { Text(bot.name).font(.headline); if let main = store.herdrMainBotLabel(bot) { HerdrMainBotStar(label: main, size: 12) } }; Text(bot.title).foregroundStyle(.secondary) } }
            Text(bot.botDescription.isEmpty ? "No description yet." : bot.botDescription).foregroundStyle(.secondary)
            if bot.backend == .herdr {
                HerdrOverviewSection(bot: bot)
                HerdrHelpersSection(bot: bot)
            }
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

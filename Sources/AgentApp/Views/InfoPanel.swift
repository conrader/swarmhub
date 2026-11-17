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
        case .model: HerdrAgentControls(bot: bot)
        case .skills: HerdrSkillsPanel(bot: bot)
        case .media: MediaTabView(bot: bot)
        }
    }

    /// Identity (a large avatar with the name under it, and the star a main bot carries), its role, where it runs
    /// and on what, its helpers, then the groups it is in.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 6) {
                BotAvatar(bot: bot, size: 72, motion: .focus, isWorking: store.isWorking(bot), probe: "overview", facing: .left).padding(.bottom, 4)
                HStack(spacing: 6) {
                    Text(bot.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if let main = store.herdrMainBotLabel(bot) { HerdrMainBotStar(label: main, size: 14) }
                }
                // A role and a description show when the bot has them; "Personal agent" was the placeholder of older versions.
                if !bot.title.isEmpty, bot.title != Bot.placeholderTitle { Text(bot.title).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                if !bot.botDescription.isEmpty {
                    Text(bot.botDescription).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
            }.frame(maxWidth: .infinity).padding(.top, 6)
            if bot.backend == .herdr {
                HerdrOverviewSection(bot: bot)
                HerdrBotProjectsSection(bot: bot, quietWhenEmpty: true)
                HerdrHelpersSection(bot: bot)
            }
            groups
        }
    }

    /// The groups this bot is in, and a way to start one with it. (A one-to-one chat has two members, the person and
    /// the bot, which needs no list.)
    private var groups: some View {
        VStack(alignment: .leading, spacing: 10) {
            let groups = store.groups.filter { $0.memberIDs.contains(bot.id) }
            if !groups.isEmpty {
                Text("Groups").font(.headline)
                ForEach(groups) { group in Button { store.open(group) } label: { Label(group.name, systemImage: "person.3") }.buttonStyle(.plain) }
            }
            Button("New group with \(bot.name)…") { store.showingNewGroup = true }.disabled(bot.isReadOnlyArchive).padding(.top, 2)
        }
    }
}

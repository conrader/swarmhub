import SwiftUI

/// The left column, like Grok Bot's (P20): round search and + at the top, one flat list (newest conversations first, a Herdr
/// bot's helper agents nested under it, then a quiet "Hidden chats" disclosure), and a bottom bar with the user's initial and a Settings pill. P47: Connect apps sits on its
/// own row directly above that bar (beside it, the Settings pill would truncate in a 240 pt sidebar).
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: Bot?
    @State private var botToDelete: Bot?; @State private var groupToDelete: GroupChat?
    @AppStorage(SidebarMetrics.accountNameKey) private var accountName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: ChromeMetrics.lightsClearance)
                HideSidebarButton()
                Button { store.showingCommandPalette = true } label: { RoundSidebarLabel(symbol: "magnifyingglass") }
                    .buttonStyle(.plain).help("Search (\(AppCommand.quickSwitcher.shortcutText))")
                    .accessibilityLabel("Search").chromeProbe("search")
                Menu {
                    Button("New Bot", systemImage: "plus") { store.showingNewBot = true }
                    Button("New Group", systemImage: "person.3") { store.showingNewGroup = true }
                    if store.grokBotPresent {
                        Button("Import from Grok Bot…", systemImage: "tray.and.arrow.down") { store.showingGrokImport = true }
                    }
                } label: { RoundSidebarLabel(symbol: "plus") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("New bot or group (\(AppCommand.newAgent.shortcutText))").accessibilityLabel("New").chromeProbe("new_bot")
            }.padding(.trailing, SidebarMetrics.listInset).frame(height: SidebarMetrics.topRow).windowDragStrip(probe: "sidebar_row")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sidebarChats) { chat in
                        switch chat {
                        case .bot(let bot): row(bot)
                        case .group(let group): GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete)
                        }
                    }
                    // Nothing hidden, nothing to unfold.
                    if !store.hiddenChatBots.isEmpty || store.groups.contains(where: \.isHidden) {
                        Button { store.showingHiddenBots.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: store.showingHiddenBots ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                                Text("Hidden chats").font(.system(size: 12))
                            }.foregroundStyle(.tertiary).padding(.horizontal, SidebarMetrics.rowPadding).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.top, 6)
                    }
                    if store.showingHiddenBots {
                        ForEach(store.hiddenChatBots) { bot in row(bot) }
                        ForEach(store.groups.filter(\.isHidden)) { group in GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete) }
                    }
                }.padding(.horizontal, SidebarMetrics.listInset).padding(.top, 4)
            }.chromeProbe("sidebar_list")
            HStack(spacing: 10) {
                // One button: the person's initial and "Settings" (two buttons that opened the same window read as two things).
                SettingsLink {
                    HStack(spacing: 8) {
                        Text(UserIdentity.initial(of: accountName)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(.tint))
                        Text("Settings").font(.system(size: 13, weight: .medium))
                    }.padding(.leading, 5).padding(.trailing, 14)
                        .frame(height: SidebarMetrics.roundButton).background(Capsule().fill(Color.primary.opacity(0.08))).contentShape(Capsule())
                }.buttonStyle(.plain).help("Settings (\(AppCommand.settings.shortcutText))").accessibilityLabel("Settings")
                Spacer()
            }.padding(.horizontal, SidebarMetrics.listInset + 4).frame(height: SidebarMetrics.bottomBar)
        }.background(AppColor.sidebar)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its chat is removed from this Mac. This can’t be undone.") }
        .alert("Delete group \(groupToDelete?.name ?? "")?", isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } })) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) { if let groupToDelete { store.deleteGroup(groupToDelete) }; groupToDelete = nil }
        } message: { Text("The group chat is removed from this Mac. Its bots and their own chats stay.") }
    }
    /// The bot's row; under it, while its Herdr agent has helper agents, one row for each. With a helper open the
    /// helper's row is the selected one.
    @ViewBuilder private func row(_ bot: Bot) -> some View {
        BotRow(bot: bot, drafts: store.drafts, selected: selection == bot && store.selectedGroup == nil && store.openHerdrHelper?.botID != bot.id, botToDelete: $botToDelete)
        if bot.backend == .herdr { HerdrHelperRows(bot: bot) }
    }
}

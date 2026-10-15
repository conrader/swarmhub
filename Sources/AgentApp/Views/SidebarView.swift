import SwiftUI

/// The left column, like Grok Bot's (P20): round search and + at the top, one flat list (newest conversations first, then a quiet
/// "Hidden chats" disclosure), and a bottom bar with the user's initial and a Settings pill.
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
                    Button("Import Template…", systemImage: "square.and.arrow.down") { store.showingTemplateImport = true }
                } label: { RoundSidebarLabel(symbol: "plus") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("New bot, group or template (\(AppCommand.newAgent.shortcutText))").accessibilityLabel("New").chromeProbe("new_bot")
            }.padding(.trailing, SidebarMetrics.listInset).frame(height: SidebarMetrics.topRow).windowDragStrip(probe: "sidebar_row")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sidebarChats) { chat in
                        switch chat {
                        case .bot(let bot): row(bot)
                        case .group(let group): GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete)
                        }
                    }
                    BoxNotConnectedSections()
                    ReportsSidebarRow(center: store.reportsCenter)
                    Button { store.showingHiddenBots.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.showingHiddenBots ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Hidden chats").font(.system(size: 12))
                        }.foregroundStyle(.tertiary).padding(.horizontal, SidebarMetrics.rowPadding).frame(height: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 6)
                    if store.showingHiddenBots {
                        ForEach(store.hiddenChatBots) { bot in row(bot) }
                        ForEach(store.groups.filter(\.isHidden)) { group in GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete) }
                    }
                }.padding(.horizontal, SidebarMetrics.listInset).padding(.top, 4)
            }.chromeProbe("sidebar_list")
            HStack(spacing: 10) {
                SettingsLink { RoundSidebarLabel(symbol: nil, text: UserIdentity.initial(of: accountName)) }
                    .buttonStyle(.plain).help("Account and settings").accessibilityLabel("Account")
                SettingsLink {
                    Text("Settings").font(.system(size: 13, weight: .medium)).padding(.horizontal, 16)
                        .frame(height: SidebarMetrics.roundButton).background(Capsule().fill(Color.primary.opacity(0.08))).contentShape(Capsule())
                }.buttonStyle(.plain).help("Settings (\(AppCommand.settings.shortcutText))").accessibilityLabel("Settings")
                Spacer()
            }.padding(.horizontal, SidebarMetrics.listInset + 4).frame(height: SidebarMetrics.bottomBar)
        }.background(AppColor.sidebar)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its local conversation history will be removed. This can’t be undone.") }
        .alert("Delete group \(groupToDelete?.name ?? "")?", isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } })) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) { if let groupToDelete { store.deleteGroup(groupToDelete) }; groupToDelete = nil }
        } message: { Text("The group’s local transcript is removed; its bots and their own chats stay.") }
    }
    private func row(_ bot: Bot) -> some View {
        BotRow(bot: bot, drafts: store.drafts, selected: selection == bot && store.selectedGroup == nil, botToDelete: $botToDelete)
    }
}

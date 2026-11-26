import SwiftUI

/// The left column, like Grok Bot's (P20): round search and + at the top, one list: pinned chats as big marks first, then the chats in
/// the user's named, foldable sections (newest conversations first inside each; with no sections and no pins it is one flat
/// list), a Herdr bot's helper agents nested under it, then a quiet "Hidden chats" disclosure, and a bottom bar with the user's initial and a Settings pill. P47: Connect apps sits on its
/// own row directly above that bar (beside it, the Settings pill would truncate in a 240 pt sidebar).
struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: Bot?
    @State private var botToDelete: Bot?; @State private var groupToDelete: GroupChat?
    @State private var sectionPrompt: SidebarSectionPrompt?; @State private var sectionToDelete: UUID?
    @AppStorage(SidebarMetrics.accountNameKey) private var accountName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer(minLength: ChromeMetrics.lightsClearance)
                HideSidebarButton()
                Button { store.showingCommandPalette = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                            Text(AppCommand.quickSwitcher.shortcutText).foregroundStyle(.secondary)
                        }.font(.caption).padding(.horizontal, 8).frame(height: 24)
                            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(AppColor.separator) }
                            .fixedSize()
                        RoundSidebarLabel(symbol: "magnifyingglass")
                    }
                }
                    .buttonStyle(.plain).help("Search (\(AppCommand.quickSwitcher.shortcutText))")
                    .accessibilityLabel("Search").chromeProbe("search").layoutPriority(1)
                Menu {
                    Button("New Bot", systemImage: "plus") { store.showingNewBot = true }
                    Button("New Group", systemImage: "person.3") { store.showingNewGroup = true }
                    Button("New Section…", systemImage: "folder.badge.plus") { sectionPrompt = .new(nil) }
                    if store.grokBotPresent {
                        Button("Import from Grok Bot…", systemImage: "tray.and.arrow.down") { store.openSetup(openWindow: openWindow, forGrok: true) }
                    }
                } label: { RoundSidebarLabel(symbol: "plus") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("New bot or group (\(AppCommand.newAgent.shortcutText))").accessibilityLabel("New").chromeProbe("new_bot")
            }.padding(.trailing, SidebarMetrics.listInset).frame(height: SidebarMetrics.topRow).windowDragStrip(probe: "sidebar_row")
            ReviewUpdatesButton()
            let layout = store.sidebarLayout
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !layout.pinned.isEmpty {
                        SidebarPinnedStrip(chats: layout.pinned, askNewSection: { sectionPrompt = .new($0) }, requestDelete: requestDelete)
                    }
                    ForEach(layout.sections) { bucket in
                        if bucket.showsHeader {
                            SidebarSectionHeader(bucket: bucket, askRename: { sectionPrompt = .rename($0) }, askDelete: askDeleteSection)
                        }
                        if !bucket.isCollapsed {
                            if bucket.showsHeader && bucket.chats.isEmpty { SidebarEmptySectionLine() }
                            ForEach(bucket.chats) { chat in
                                switch chat {
                                case .bot(let bot): row(bot)
                                case .group(let group): GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete, askNewSection: { sectionPrompt = .new($0) })
                                }
                            }
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
                        ForEach(store.groups.filter(\.isHidden)) { group in GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete, askNewSection: { sectionPrompt = .new($0) }) }
                    }
                }.padding(.horizontal, SidebarMetrics.listInset).padding(.top, 4)
            }.chromeProbe("sidebar_list")
            // The bottom bar floats over the list where the Mac has Liquid Glass: the rows pass beneath it.
            .floatingBar(edge: .bottom, backing: AppColor.sidebar) { bottomBar }
        }.background(AppColor.sidebar)
        .modifier(SidebarSectionPrompts(prompt: $sectionPrompt, sectionToDelete: $sectionToDelete))
        .alert(BotRemovalCopy.title(botToDelete?.name ?? "bot"), isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text(BotRemovalCopy.message(server: botToDelete.flatMap(store.herdrEndingPlace(for:)))) }
        .alert("Delete group \(groupToDelete?.name ?? "")?", isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } })) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) { if let groupToDelete { store.deleteGroup(groupToDelete) }; groupToDelete = nil }
        } message: { Text("The group chat is removed from this Mac. Its bots and their own chats stay.") }
    }

    /// Opens the delete confirmation for a chat from a pinned tile.
    private func requestDelete(_ chat: SidebarChat) {
        switch chat { case .bot(let bot): botToDelete = bot; case .group(let group): groupToDelete = group }
    }

    /// An empty section goes at once; one with chats asks first (its chats only move to Unsectioned).
    private func askDeleteSection(_ id: UUID) {
        if store.sidebar.section(id)?.chats.isEmpty ?? true { store.deleteSidebarSection(id) } else { sectionToDelete = id }
    }

    /// The account and Settings button.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            // One button: the person's initial and "Settings" (two buttons that opened the same window read as two things).
            SettingsLink {
                HStack(spacing: 8) {
                    Text(UserIdentity.initial(of: accountName)).font(.system(size: 12, weight: .bold)).foregroundStyle(AppColor.onAccent)
                        .frame(width: 22, height: 22).background(Circle().fill(.tint))
                    Text("Settings").font(.system(size: 13, weight: .medium))
                }.padding(.leading, 5).padding(.trailing, 14)
                    .frame(height: SidebarMetrics.roundButton).glassSurface(in: Capsule(), interactive: true, fallback: Color.primary.opacity(0.08), border: Color.clear).contentShape(Capsule())
            }.buttonStyle(.plain).help("Settings (\(AppCommand.settings.shortcutText))").accessibilityLabel("Settings")
            Spacer(minLength: 2)
            Button { store.showingActivity = true } label: {
                Label("Activity", systemImage: AppCommand.activity.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: SidebarMetrics.roundButton)
            }.buttonStyle(.plain).help("Workspace activity (\(AppCommand.activity.shortcutText))")
        }.padding(.horizontal, SidebarMetrics.listInset + 4).frame(height: SidebarMetrics.bottomBar)
    }

    /// The bot's row; under it, while its Herdr agent has helper agents, one row for each. With a helper open the
    /// helper's row is the selected one.
    @ViewBuilder private func row(_ bot: Bot) -> some View {
        SidebarBotSessions(bot: bot) {
            BotRow(bot: bot, drafts: store.drafts, selected: selection == bot && store.selectedGroup == nil && store.openHerdrHelper?.botID != bot.id, botToDelete: $botToDelete, askNewSection: { sectionPrompt = .new($0) })
        }
    }
}

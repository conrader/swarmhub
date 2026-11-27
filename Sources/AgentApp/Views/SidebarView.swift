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
            VStack(spacing: 6) {
                Button { store.showingCommandPalette = true } label: {
                    HStack {
                        Text("Jump to bot or Page…").lineLimit(1)
                        Spacer()
                        Text(AppCommand.quickSwitcher.shortcutText).font(.caption.monospaced())
                    }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 9).frame(height: 28)
                        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(AppColor.separator) }
                }.buttonStyle(.plain).accessibilityLabel("Search").chromeProbe("search")
                SidebarAttentionButton()
            }.padding(.horizontal, SidebarMetrics.listInset).padding(.vertical, 4)
            ReviewUpdatesButton()
            let layout = store.sidebarLayout
            let sessions = Dictionary(grouping: store.herdrHelpers.keys.filter { $0.source == nil && store.herdrHelpers[$0]?.hasSidebarSessions == true }, by: \.botID)
            let workers = store.sidebarCodejobs
            SidebarSessionScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !layout.pinned.isEmpty {
                        let pinnedParents = layout.pinned.compactMap { chat -> Bot? in
                            if case .bot(let bot) = chat, sessions[bot.id] != nil || workers[bot.id] != nil { return bot }
                            return nil
                        }
                        let tiles = layout.pinned.filter { chat in
                            if case .bot(let bot) = chat { return sessions[bot.id] == nil && workers[bot.id] == nil }
                            return true
                        }
                        if !tiles.isEmpty {
                            SidebarPinnedStrip(chats: tiles, askNewSection: { sectionPrompt = .new($0) }, requestDelete: requestDelete)
                        }
                        ForEach(pinnedParents) { bot in row(bot, parents: sessions[bot.id] ?? [], workers: workers[bot.id] ?? []) }
                    }
                    ForEach(layout.sections) { bucket in
                        if bucket.showsHeader {
                            SidebarSectionHeader(bucket: bucket, askRename: { sectionPrompt = .rename($0) }, askDelete: askDeleteSection)
                        }
                        if !bucket.isCollapsed {
                            if bucket.showsHeader && bucket.chats.isEmpty { SidebarEmptySectionLine() }
                            ForEach(bucket.chats) { chat in
                                switch chat {
                                case .bot(let bot): row(bot, parents: sessions[bot.id] ?? [], workers: workers[bot.id] ?? [])
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
                        ForEach(store.hiddenChatBots) { bot in row(bot, parents: sessions[bot.id] ?? [], workers: workers[bot.id] ?? []) }
                        ForEach(store.groups.filter(\.isHidden)) { group in GroupRow(group: group, drafts: store.drafts, botToDelete: $groupToDelete, askNewSection: { sectionPrompt = .new($0) }) }
                    }
                }.padding(.horizontal, SidebarMetrics.listInset).padding(.top, 4)
            }.chromeProbe("sidebar_list")
            // The bottom bar floats over the list where the Mac has Liquid Glass: the rows pass beneath it.
            .floatingBar(edge: .bottom, backing: AppColor.sidebar) {
                VStack(spacing: 0) {
                    HStack {
                        let endpoints = Set(store.herdrServers.filter { $0.kind == .ssh }.compactMap(\.sshEndpoint)
                            .map { "\($0.host.lowercased()):\($0.port ?? 22)" })
                        Text(endpoints.count == 1 ? "1 SSH host" : "\(endpoints.count) SSH hosts")
                            .help("Configured SSH hosts")
                        Spacer()
                        Text(AppStore.botCount(store.bots.filter { !$0.isReadOnlyArchive }.count))
                            .help("Bots in this workspace, including hidden bots")
                    }.font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, SidebarMetrics.listInset + 6).padding(.top, 6)
                    bottomBar
                }
            }
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
        HStack(spacing: 5) {
            // One button: the person's initial and "Settings" (two buttons that opened the same window read as two things).
            SettingsLink {
                HStack(spacing: 5) {
                    Text(UserIdentity.initial(of: accountName)).font(.system(size: 12, weight: .bold)).foregroundStyle(AppColor.onAccent)
                        .frame(width: 22, height: 22).background(Circle().fill(.tint))
                    Text("Settings").font(.system(size: 13, weight: .medium)).fixedSize()
                }.padding(.leading, 5).padding(.trailing, 9)
                    .frame(height: SidebarMetrics.roundButton).glassSurface(in: Capsule(), interactive: true, fallback: Color.primary.opacity(0.08), border: Color.clear).contentShape(Capsule())
            }.buttonStyle(.plain).help("Settings (\(AppCommand.settings.shortcutText))").accessibilityLabel("Settings")
            Spacer(minLength: 2)
            Button {
                if let server = store.selectedBot.map({ store.herdrServer(for: $0) }) ?? store.herdrServers.first {
                    openWindow(value: TerminalBrowserRequest(server: server))
                }
            } label: { Image(systemName: "terminal").frame(width: 24, height: SidebarMetrics.roundButton) }
                .buttonStyle(.plain).accessibilityLabel("Live terminals").help("Preview agent and helper terminals")
            Button { store.showOnlyAttention = false; store.showingActivity = true } label: {
                ViewThatFits(in: .horizontal) {
                    Label("Activity", systemImage: AppCommand.activity.icon).fixedSize()
                    Image(systemName: AppCommand.activity.icon).frame(width: 24)
                }.font(.system(size: 13, weight: .medium))
                    .frame(height: SidebarMetrics.roundButton)
            }.buttonStyle(.plain).accessibilityLabel("Workspace activity").help("Workspace activity (\(AppCommand.activity.shortcutText))")
        }.padding(.horizontal, SidebarMetrics.listInset).frame(height: SidebarMetrics.bottomBar)
    }

    /// The bot's row; under it, while its Herdr agent has helper agents, one row for each. With a helper open the
    /// helper's row is the selected one.
    @ViewBuilder private func row(_ bot: Bot, parents: [HerdrHelperParent], workers: [HerdrCodejobRow]) -> some View {
        SidebarBotSessions(bot: bot, parents: parents, workers: workers) {
            BotRow(bot: bot, drafts: store.drafts, selected: !store.showOnlyAttention && selection == bot && store.selectedGroup == nil && store.openHerdrHelper?.botID != bot.id, botToDelete: $botToDelete, askNewSection: { sectionPrompt = .new($0) })
        }
    }
}

/// Scroll only on explicit navigation. Polling and opening a terminal preview preserve the reading position.
private struct SidebarSessionScrollView<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .onChange(of: store.sidebarReveal?.request) {
                    guard let target = store.sidebarReveal?.target else { return }
                    // LazyVStack may not have built the nested row yet. Materialize its bot first.
                    proxy.scrollTo(target.parent.botID)
                    DispatchQueue.main.async {
                        guard store.sidebarReveal?.target == target else { return }
                        proxy.scrollTo(target)
                    }
                }
        }
    }
}

private struct SidebarAttentionButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.workspaceApprovals) private var inboxes
    @Environment(\.workspaceAttention) private var readings
    @State private var chatCount = 0

    var body: some View {
        let failures = store.herdrServers.reduce(0) { count, server in
            count + (readings[server.id].flatMap { $0.server == server ? $0.failures.count : nil } ?? 0)
        }
        let count = chatCount + failures
        Button {
            store.showOnlyAttention = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "tray").foregroundStyle(.secondary)
                Text("Needs Attention").font(.callout.weight(.medium))
                Spacer(minLength: 2)
                Text(String(count)).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((count == 0 ? Color.secondary : Color.accentColor).opacity(0.14), in: Capsule())
            }.padding(.horizontal, 9).frame(height: 32)
                .background(store.showOnlyAttention ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(AppColor.separator) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Needs Attention").accessibilityValue(String(count))
            .help("Pending requests, interrupted replies and failed checks. Open to check saved SSH servers.")
            .task(id: inboxes) {
                while !Task.isCancelled {
                    chatCount = store.workspaceActivity(inboxes: inboxes, attentionOnly: true).reduce(0) { count, row in
                        var requests = store.workspaceReviews(in: row.chat, inboxes: inboxes).count
                        if case .bot(let bot) = row.chat { requests += store.pendingHerdrBots(for: bot).count }
                        return count + max(1, requests)
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }
}

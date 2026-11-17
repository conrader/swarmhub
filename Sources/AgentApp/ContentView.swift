import SwiftUI

struct ContentView: View {
    static let windowID = "workspace"
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pendingCommand: AppCommand?
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { store.sidebarHidden ? .detailOnly : .all }, set: { store.sidebarHidden = $0 == .detailOnly })) {
            SidebarView(selection: $store.selectedBot).navigationSplitViewColumnWidth(min: SidebarMetrics.width.min, ideal: SidebarMetrics.width.ideal, max: SidebarMetrics.width.max)
                .background(SidebarWidthClamp())
                .toolbar(removing: .sidebarToggle).ignoresSafeArea(.container, edges: .top)
        } detail: {
            Group {
                if let group = store.selectedGroup {
                    GroupChatView(group: group).frame(minWidth: 500).rightColumn(isPresented: $store.showInfo) { GroupInfoPanel(group: group) }
                } else if let bot = store.selectedBot, let helper = store.openHerdrHelper, helper.botID == bot.id {
                    // One of the bot's helper agents, read-only, in place of its chat.
                    HerdrHelperView(bot: bot, selection: helper).id(helper).frame(minWidth: 500)
                } else if let bot = store.selectedBot {
                    ChatView(bot: bot).frame(minWidth: 500).rightColumn(isPresented: $store.showInfo) { InfoPanel(bot: bot) }
                } else {
                    SetupEmptyState()
                        .overlay(alignment: .top) { if store.sidebarHidden { WindowDragArea().frame(height: ChromeMetrics.titleRow).chromeProbe("empty_strip") } }
                }
            }.ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) { StoreRestorePrompt() }
        }.navigationSplitViewStyle(.balanced).tint(AppTheme.accentColor(for: accent)).background(AppColor.chat)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // Transient network trouble is this line, never the alert below.
                if let notice = store.connectionNotice { ConnectionNoticeBar(text: notice) { store.errorMessage = nil } }
                // Bots of an older version were removed when the store was opened (`LegacyStore`): said once, until dismissed.
                if let notice = store.legacyNotice {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle").accessibilityHidden(true)
                        Text(notice).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Button("Dismiss") { store.dismissLegacyNotice() }
                            .accessibilityLabel("Dismiss the note about removed bots")
                    }.font(.callout).padding(12).background(.regularMaterial)
                }
            }
        }
        .task { store.startHerdrHelperPolling(); store.startLaunchWork(); store.startTeamCoordination(); if FirstRun.settle(store) { store.openSetup(openWindow: openWindow) } }
        // "New agent" with no server opens the setup window instead of an editor whose bot could not answer.
        .sheet(isPresented: Binding(get: { store.showingNewBot && store.herdrConfigured }, set: { store.showingNewBot = $0 })) { BotEditorView(bot: nil) }
        .onChange(of: store.showingNewBot) { _, shown in if shown, !store.herdrConfigured { store.showingNewBot = false; store.openSetup(openWindow: openWindow) } }
        .sheet(isPresented: $store.showingTemplateImport) { TemplateImportView() }
        .sheet(isPresented: $store.showingGrokImport) { GrokImportSheet(store: store) }
        .sheet(isPresented: $store.showingNewGroup) { NewGroupSheet(preselected: store.selectedGroup == nil ? Set(store.selectedBot.map { [$0.id] } ?? []) : []) }
        .sheet(item: $store.editingBot) { BotEditorView(bot: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in store.showInfo.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in store.sidebarHidden.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in store.showingNewBot = true }
        .onReceive(NotificationCenter.default.publisher(for: .commandPalette)) { _ in store.showingCommandPalette = true }
        .sheet(isPresented: $store.showingCommandPalette, onDismiss: {
            if let command = pendingCommand {
                pendingCommand = nil
                command.perform(in: store, openSettings: openSettings, openWindow: openWindow)
            }
        }) { CommandPaletteView(selectCommand: { pendingCommand = $0 }, openSetup: { store.openSetup(openWindow: openWindow) }) }
        .alert("Something went wrong", isPresented: Binding(get: { store.modalErrorMessage != nil }, set: { if !$0, store.modalErrorMessage != nil { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.modalErrorMessage ?? "") }
    }
}

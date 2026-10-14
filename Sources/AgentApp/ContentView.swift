import SwiftUI

struct ContentView: View {
    static let windowID = "workspace"
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pendingCommand: AppCommand?
    @State private var pendingThread: BotThreadKey?
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
                } else if let bot = store.selectedBot {
                    ChatView(bot: bot).frame(minWidth: 500).rightColumn(isPresented: $store.showInfo) { InfoPanel(bot: bot) }
                } else {
                    SetupEmptyState()
                        .overlay(alignment: .top) { if store.sidebarHidden { WindowDragArea().frame(height: ChromeMetrics.titleRow).chromeProbe("empty_strip") } }
                }
            }.ignoresSafeArea(.container, edges: .top)
        }.navigationSplitViewStyle(.balanced).tint(AppTheme.accentColor(for: accent)).background(AppColor.chat)
        .task { store.startRoutinePolling(); store.startLaunchWork(); if FirstRun.settle(store) { store.openSetup(openWindow: openWindow) } }
        // P21 item 8: "New agent" with no box opens the setup window instead of an editor that could only make a mock.
        .sheet(isPresented: Binding(get: { store.showingNewBot && store.boxConfigured }, set: { store.showingNewBot = $0 })) { BotEditorView(bot: nil) }
        .onChange(of: store.showingNewBot) { _, shown in if shown, !store.boxConfigured { store.showingNewBot = false; store.openSetup(openWindow: openWindow) } }
        .sheet(isPresented: $store.showingTemplateImport) { TemplateImportView() }
        .sheet(isPresented: $store.showingGrokImport) { GrokImportSheet(store: store) }
        .sheet(isPresented: $store.showingNewGroup) { NewGroupSheet(preselected: store.selectedGroup == nil ? Set(store.selectedBot.map { [$0.id] } ?? []) : []) }
        .sheet(item: $store.editingBot) { BotEditorView(bot: $0) }
        .sheet(item: $store.openBotThread) { BotThreadSheet(center: store.botMessages, key: $0) }
        .sheet(item: $store.adoptionOffer) { AdoptionSheet(offer: $0) { store.adoptionOffer = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in store.showInfo.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in store.sidebarHidden.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in store.showingNewBot = true }
        .onReceive(NotificationCenter.default.publisher(for: .commandPalette)) { _ in store.showingCommandPalette = true }
        .sheet(isPresented: $store.showingCommandPalette, onDismiss: {
            if let command = pendingCommand {
                pendingCommand = nil
                command.perform(in: store, openSettings: openSettings, openWindow: openWindow)
            }
            if let thread = pendingThread { pendingThread = nil; store.openThread(thread) }
        }) { CommandPaletteView(selectCommand: { pendingCommand = $0 }, openSetup: { store.openSetup(openWindow: openWindow) }, openThread: { pendingThread = $0 }) }
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
}

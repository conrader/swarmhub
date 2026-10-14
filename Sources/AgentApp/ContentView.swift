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
                } else if let bot = store.selectedBot {
                    ChatView(bot: bot).frame(minWidth: 500).rightColumn(isPresented: $store.showInfo) { InfoPanel(bot: bot) }
                } else {
                    SetupEmptyState()
                        .overlay(alignment: .top) { if store.sidebarHidden { WindowDragArea().frame(height: ChromeMetrics.titleRow).chromeProbe("empty_strip") } }
                }
            }.ignoresSafeArea(.container, edges: .top)
        }.navigationSplitViewStyle(.balanced).tint(AppTheme.accentColor(for: accent)).background(AppColor.chat)
        .task { store.startRoutinePolling(); if FirstRun.settle(store) { store.openSetup(openWindow: openWindow) } }
        // P21 item 8: "New agent" with no box opens the setup window instead of an editor that could only make a mock.
        .sheet(isPresented: Binding(get: { store.showingNewBot && store.boxConfigured }, set: { store.showingNewBot = $0 })) { BotEditorView(bot: nil) }
        .onChange(of: store.showingNewBot) { _, shown in if shown, !store.boxConfigured { store.showingNewBot = false; store.openSetup(openWindow: openWindow) } }
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
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
}

private struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    let selectCommand: (AppCommand) -> Void
    let openSetup: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Jump to an agent or action", text: $query).textFieldStyle(.plain).font(.title3).focused($searchFocused); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
            Divider()
            ScrollView { VStack(spacing: 4) {
                ForEach(store.bots.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { bot in action(bot.name, icon: "message") { store.open(bot) } }
                ForEach(store.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { group in action(group.name, icon: "person.3") { store.open(group) } }
                Divider().padding(.vertical, 4)
                ForEach(AppCommand.allCases.filter { $0 != .quickSwitcher && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }) { command in
                    action(command.title, icon: command.icon, shortcut: command.shortcutText) { selectCommand(command) }
                        .disabled(!command.isEnabled(in: store))
                }
                if query.isEmpty || setupTitle.localizedCaseInsensitiveContains(query) { action(setupTitle, icon: "link", perform: openSetup) }
            }.padding(8) }
        }.frame(width: 480, height: 380).background(AppColor.panel).onAppear { searchFocused = true }
    }
    private var setupTitle: String { store.boxConfigured ? SimpleCopy.changeConnection : SimpleCopy.setUp }
    private func action(_ title: String, icon: String, shortcut: String? = nil, perform: @escaping () -> Void) -> some View { Button { perform(); dismiss() } label: { HStack { Image(systemName: icon).frame(width: 24); Text(title); Spacer(); if let shortcut { Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary) } }.padding(9).contentShape(Rectangle()) }.buttonStyle(.plain) }
}

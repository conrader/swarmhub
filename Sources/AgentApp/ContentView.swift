import SwiftUI

struct ContentView: View {
    static let windowID = "workspace"
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var windowActivity
    @State private var readingWindow = UUID()
    @State private var pendingCommand: AppCommand?
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    private var hasCompetingVaultSheet: Bool {
        (store.showingNewBot && store.herdrConfigured) || store.showingTemplateImport || store.showingGrokImport
            || store.showingNewGroup || store.editingBot != nil || store.showingCommandPalette || store.showingActivity || store.modalErrorMessage != nil
    }

    private func continueLaunch() {
        guard store.persistenceEnabled || store.isSetupPreview else { return }
        store.startHerdrHelperPolling()
        store.startLaunchWork()
        store.startTeamCoordination()
        if FirstRun.settle(store) { store.openSetup(openWindow: openWindow) }
    }

    @ViewBuilder private func inspector<Panel: View>(@ViewBuilder details: () -> Panel) -> some View {
        if let request = store.inspectorTerminal {
            WorkspaceTerminals(request: request, docked: true).id(request.id)
        } else { details() }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(get: { store.sidebarHidden ? .detailOnly : .all }, set: { store.sidebarHidden = $0 == .detailOnly })) {
            SidebarView(selection: $store.selectedBot).navigationSplitViewColumnWidth(min: SidebarMetrics.width.min, ideal: SidebarMetrics.width.ideal, max: SidebarMetrics.width.max)
                .background(SidebarWidthClamp())
                .disabled(store.storeRestoreOffer != nil)
                .toolbar(removing: .sidebarToggle).ignoresSafeArea(.container, edges: .top)
        } detail: {
            Group {
                if store.showOnlyAttention {
                    let hasInspector = store.selectedGroup != nil || store.selectedBot != nil || store.inspectorTerminal != nil
                    WorkspaceActivityView(attentionOnly: true)
                        .frame(minWidth: ChromeMetrics.chatWidthWithInspector)
                        .rightColumn(isPresented: hasInspector ? $store.showInfo : .constant(false), expandable: store.inspectorTerminal != nil) {
                            inspector {
                                if let group = store.selectedGroup { GroupInfoPanel(group: group) }
                                else if let bot = store.selectedBot { InfoPanel(bot: bot) }
                            }
                        }
                } else if let group = store.selectedGroup {
                    GroupChatView(group: group).id(group.id).frame(minWidth: ChromeMetrics.chatWidthWithInspector).rightColumn(isPresented: $store.showInfo, expandable: store.inspectorTerminal != nil) { inspector { GroupInfoPanel(group: group) } }
                } else if let bot = store.selectedBot, let helper = store.openHerdrHelper, helper.botID == bot.id {
                    // One of the bot's helper agents, read-only, in place of its chat.
                    Group {
                        if let native = helper.native {
                            NativeSessionView(bot: bot, selection: helper, native: native)
                        } else {
                            HerdrHelperView(bot: bot, selection: helper)
                        }
                    }.id(helper).frame(minWidth: ChromeMetrics.chatWidthWithInspector)
                        .rightColumn(isPresented: $store.showInfo, expandable: store.inspectorTerminal != nil) { inspector { InfoPanel(bot: bot) } }
                } else if let bot = store.selectedBot {
                    ChatView(bot: bot).id(bot.id).frame(minWidth: ChromeMetrics.chatWidthWithInspector).rightColumn(isPresented: $store.showInfo, expandable: store.inspectorTerminal != nil) { inspector { InfoPanel(bot: bot) } }
                } else {
                    SetupEmptyState()
                        .overlay(alignment: .topLeading) {
                            if store.sidebarHidden {
                                HStack {
                                    ShowSidebarItem()
                                    Spacer()
                                }
                                .padding(.horizontal, ChromeMetrics.headerPadding)
                                .frame(height: ChromeMetrics.titleRow)
                                .windowDragStrip(probe: "empty_strip")
                            }
                        }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(store.chatSSHLoginRequests) { server in ChatSSHLoginBar(server: server) }
                }
            }
            .disabled(store.storeRestoreOffer != nil).ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) { StoreRestorePrompt() }
        }.navigationSplitViewStyle(.balanced).tint(AppTheme.accentColor(for: accent)).background(AppColor.chat)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Transient network trouble is this line, never the alert below.
            if let notice = store.connectionNotice { ConnectionNoticeBar(text: notice) { store.dismissError() } }
        }
        .environment(\.timeZone, store.personDisplayZone)
        .onChange(of: windowActivity, initial: true) { _, activity in
            store.workspaceFocusChanged(readingWindow, focused: activity == .key)
        }
        .onDisappear { store.workspaceFocusChanged(readingWindow, focused: false) }
        .task { if store.storeRestoreOffer == nil { continueLaunch() } }
        .onChange(of: store.storeRestoreOffer) { _, offer in
            if offer == nil { continueLaunch() }
        }
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
        .sheet(isPresented: $store.showingActivity) { WorkspaceActivityView() }
        .modifier(WorkspaceApprovalReader())
        .modifier(HerdrVaultPrompts(anotherSheet: hasCompetingVaultSheet))
        .alert("Something went wrong", isPresented: Binding(get: { store.modalErrorMessage != nil }, set: { if !$0, store.modalErrorMessage != nil { store.dismissError() } })) { Button("OK") { store.dismissError() } } message: { Text(store.modalErrorMessage ?? "") }
    }
}

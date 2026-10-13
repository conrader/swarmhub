import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $store.selectedBot).navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 224)
        } detail: {
            if let bot = store.selectedBot {
                HStack(spacing: 0) {
                    ChatView(bot: bot).frame(minWidth: 500)
                    if store.showInfo { Divider(); InfoPanel(bot: bot) }
                }
            } else { ContentUnavailableView("Choose an agent", systemImage: "bubble.left.and.bubble.right", description: Text("Select an agent from the sidebar to begin.")) }
        }.navigationSplitViewStyle(.balanced).tint(.primary).background(AppColor.chat)
        .task { store.startRoutinePolling() }
        .sheet(isPresented: $store.showingNewBot) { BotEditorView(bot: nil) }
        .sheet(isPresented: $store.showingTemplateImport) { TemplateImportView() }
        .sheet(item: $store.editingBot) { BotEditorView(bot: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in store.showInfo.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in store.showingNewBot = true }
        .onReceive(NotificationCenter.default.publisher(for: .commandPalette)) { _ in store.showingCommandPalette = true }
        .sheet(isPresented: $store.showingCommandPalette) { CommandPaletteView() }
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
}

private struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Jump to an agent or action", text: $query).textFieldStyle(.plain).font(.title3) }.padding(16)
            Divider()
            ScrollView { VStack(spacing: 4) {
                action("New agent", icon: "plus") { store.showingNewBot = true }
                action("Open Settings", icon: "gearshape") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                ForEach(store.bots.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { bot in action(bot.name, icon: "message") { store.selectedBot = bot } }
            }.padding(8) }
        }.frame(width: 480, height: 380).background(AppColor.panel)
    }
    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View { Button { perform(); dismiss() } label: { HStack { Image(systemName: icon).frame(width: 24); Text(title); Spacer() }.padding(9).contentShape(Rectangle()) }.buttonStyle(.plain) }
}

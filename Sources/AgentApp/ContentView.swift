import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = "System"
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
        }.navigationSplitViewStyle(.balanced).tint(.primary).preferredColorScheme(scheme)
        .sheet(isPresented: $store.showingNewBot) { BotEditorView(bot: nil) }
        .sheet(item: $store.editingBot) { BotEditorView(bot: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in store.showInfo.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in store.showingNewBot = true }
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
    private var scheme: ColorScheme? { appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil }
}

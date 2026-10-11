import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        NavigationSplitView {
            SidebarView(bots: store.bots, selection: $store.selectedBot)
        } detail: {
            if let bot = store.selectedBot { HSplitView { ChatView(bot: bot).frame(minWidth: 500); if store.showSubAgents { SubAgentsPanel(tasks: store.subAgents) } } }
            else { ContentUnavailableView("Choose a bot", systemImage: "bubble.left.and.bubble.right") }
        }
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
}

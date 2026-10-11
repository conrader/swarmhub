import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = "System"; @AppStorage("accentColor") private var accent = "Blue"
    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $store.selectedBot).navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 290)
        } detail: {
            if let bot = store.selectedBot {
                HStack(spacing: 0) { ChatView(bot: bot).frame(minWidth: 520); if store.showInfo { Divider(); InfoPanel(bot: bot).transition(.move(edge: .trailing).combined(with: .opacity)) } }
            } else { ContentUnavailableView("Choose an agent", systemImage: "bubble.left.and.bubble.right", description: Text("Select an agent from the sidebar to begin.")) }
        }.navigationSplitViewStyle(.balanced).tint(Color.appAccent(accent)).preferredColorScheme(scheme)
        .sheet(isPresented: $store.showingNewBot) { BotEditorView(bot: nil) }
        .sheet(item: $store.editingBot) { BotEditorView(bot: $0) }
        .sheet(isPresented: $store.showCommandPalette) { CommandPaletteView() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInfo)) { _ in withAnimation { store.showInfo.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: .showPalette)) { _ in store.showCommandPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .newBot)) { _ in store.showingNewBot = true }
        .alert("Backend Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
    }
    private var scheme: ColorScheme? { appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil }
}

private struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; @Environment(\.openSettings) private var openSettings; @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Type a command or agent name…", text: $query).textFieldStyle(.plain).font(.title3) }.padding(16)
            Divider(); ScrollView { VStack(alignment: .leading, spacing: 5) {
                Text("QUICK ACTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 10)
                command("New agent", icon: "plus") { dismiss(); store.showingNewBot = true }; command("Open Settings", icon: "gearshape") { dismiss(); openSettings() }
                Text("AGENTS").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 10)
                ForEach(store.bots.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { bot in command(bot.name, icon: "person.crop.circle") { store.selectedBot = bot; dismiss() } }
            }.padding(6) }
        }.frame(width: 520, height: 430)
    }
    private func command(_ title: String, icon: String, action: @escaping () -> Void) -> some View { Button(action: action) { HStack { Image(systemName: icon).frame(width: 22); Text(title); Spacer(); Image(systemName: "return").font(.caption).foregroundStyle(.tertiary) }.contentShape(Rectangle()).padding(.horizontal, 11).frame(height: 38) }.buttonStyle(.plain).background(.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 8)) }
}

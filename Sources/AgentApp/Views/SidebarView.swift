import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: Bot?
    @State private var search = ""; @State private var agentsExpanded = true; @State private var botToDelete: Bot?
    private var filtered: [Bot] { search.isEmpty ? store.bots : store.bots.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.lastMessageSnippet.localizedCaseInsensitiveContains(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppConstants.name).font(.system(size: 19, weight: .semibold)); Spacer()
                Button { store.showingNewBot = true } label: { Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).background(.primary.opacity(0.06), in: Circle()).help("New bot")
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(.tertiary); TextField("Search", text: $search).textFieldStyle(.plain) }
                .padding(.horizontal, 10).frame(height: 34).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 13)
            ScrollView {
                DisclosureGroup(isExpanded: $agentsExpanded) {
                    LazyVStack(spacing: 3) { ForEach(filtered) { bot in row(bot) } }.padding(.top, 5)
                } label: { Text("Agents").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.7) }
                .padding(.horizontal, 10)
            }
            Divider().opacity(0.55)
            SettingsLink {
                HStack(spacing: 10) {
                    ZStack { Circle().fill(.quaternary); Image(systemName: "person.fill").foregroundStyle(.secondary) }.frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) { Text("Konrad").font(.callout.weight(.medium)); Text("Account & settings").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "ellipsis").foregroundStyle(.tertiary)
                }.contentShape(Rectangle()).padding(.horizontal, 13).padding(.vertical, 11)
            }.buttonStyle(.plain)
        }.background(.ultraThinMaterial)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its local conversation history will be removed. This can’t be undone.") }
    }
    private func row(_ bot: Bot) -> some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { selection = bot; bot.unreadCount = 0 } } label: {
            HStack(spacing: 10) {
                BotAvatar(bot: bot, size: 38)
                VStack(alignment: .leading, spacing: 3) { Text(bot.name).font(.callout.weight(.semibold)).foregroundStyle(.primary).lineLimit(1); Text(bot.lastMessageSnippet).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 5)
                if bot.unreadCount > 0 { Text("\(bot.unreadCount)").font(.caption2.bold()).foregroundStyle(.white).frame(minWidth: 18, minHeight: 18).background(Color.accentColor, in: Capsule()) }
            }.padding(.horizontal, 8).padding(.vertical, 7).contentShape(RoundedRectangle(cornerRadius: 11)).background(selection == bot ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).contextMenu {
            Button("Rename", systemImage: "pencil") { store.editingBot = bot }; Button("Settings", systemImage: "gearshape") { store.editingBot = bot }
            Divider(); Button("Delete", systemImage: "trash", role: .destructive) { botToDelete = bot }
        }
    }
}

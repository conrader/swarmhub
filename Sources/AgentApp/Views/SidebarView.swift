import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: Bot?
    @State private var botToDelete: Bot?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppConstants.name).font(.system(size: 14, weight: .semibold)); Spacer()
                Button { store.showingNewBot = true } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("New bot")
            }.padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 9)
            ScrollView {
                LazyVStack(spacing: 2) { ForEach(store.bots) { bot in row(bot) } }.padding(.horizontal, 8)
            }
            SettingsLink {
                HStack(spacing: 9) { Image(systemName: "person.crop.circle.fill").font(.system(size: 25)).foregroundStyle(.secondary); Text("Konrad").font(.system(size: 13, weight: .medium)); Spacer() }
                    .contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }.background(.bar)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its local conversation history will be removed. This can’t be undone.") }
    }
    private func row(_ bot: Bot) -> some View {
        Button { selection = bot; bot.unreadCount = 0 } label: {
            HStack(spacing: 9) {
                BotAvatar(bot: bot, size: 28)
                Text(bot.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 5)
                if bot.unreadCount > 0 { Circle().fill(.primary.opacity(0.72)).frame(width: 6, height: 6) }
            }.padding(.horizontal, 7).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 7)).background(selection == bot ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).contextMenu {
            Button("Edit", systemImage: "pencil") { store.editingBot = bot }
            Divider(); Button("Delete", systemImage: "trash", role: .destructive) { botToDelete = bot }
        }
    }
}

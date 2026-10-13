import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: Bot?
    @State private var botToDelete: Bot?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppConstants.name).font(.system(size: 14, weight: .semibold)); Spacer()
                Button { store.showingTemplateImport = true } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Import template")
                Button { store.showingNewBot = true } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("New bot")
            }.padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 9)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionLabel("MY BOTS")
                    ForEach(store.bots.filter { !$0.isHidden }) { bot in row(bot) }
                    sectionLabel("WORKSPACE")
                    Button { store.showingHiddenBots.toggle() } label: { Label("Hidden chats", systemImage: "eye.slash").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 9).frame(height: 34) }.buttonStyle(.plain)
                    if store.showingHiddenBots { ForEach(store.bots.filter(\.isHidden)) { bot in row(bot) } }
                }.padding(.horizontal, 8)
            }
            SettingsLink {
                HStack(spacing: 9) { Image(systemName: "person.crop.circle.fill").font(.system(size: 25)).foregroundStyle(.secondary); Text("Konrad").font(.system(size: 13, weight: .medium)); Spacer() }
                    .contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }.background(AppColor.sidebar)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its local conversation history will be removed. This can’t be undone.") }
    }
    private func sectionLabel(_ value: String) -> some View { Text(value).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 12).padding(.bottom, 4) }
    private func row(_ bot: Bot) -> some View {
        Button { store.open(bot) } label: {
            HStack(spacing: 9) {
                BotAvatar(bot: bot, size: 28)
                Text(bot.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 5)
                if bot.isUnread { Circle().fill(.primary.opacity(0.72)).frame(width: 6, height: 6) }
            }.padding(.horizontal, 7).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 7)).background(selection == bot ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).contextMenu {
            Button("Edit", systemImage: "pencil") { store.editingBot = bot }
            if !bot.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(bot) } }
            Button(bot.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: bot.isHidden ? "eye" : "eye.slash") { bot.isHidden.toggle(); store.save() }
            Button(bot.notificationsEnabled ? "Mute Notifications" : "Enable Notifications", systemImage: bot.notificationsEnabled ? "bell.slash" : "bell") { bot.notificationsEnabled.toggle(); store.save() }
            Divider(); Button("Delete", systemImage: "trash", role: .destructive) { botToDelete = bot }
        }
    }
}

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selection: Bot?
    @State private var botToDelete: Bot?; @State private var groupToDelete: GroupChat?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer(minLength: ChromeMetrics.lightsClearance)
                HideSidebarButton()
                Button { store.showingTemplateImport = true } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Import template")
                    .accessibilityLabel("Import template").chromeProbe("import_template")
                Button { store.showingNewBot = true } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("New bot")
                    .accessibilityLabel("New bot").chromeProbe("new_bot")
            }.padding(.trailing, 10).frame(height: ChromeMetrics.titleRow).windowDragStrip(probe: "sidebar_row")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionLabel("MY BOTS")
                    ForEach(store.bots.filter { !$0.isHidden }) { bot in row(bot) }
                    HStack { sectionLabel("GROUPS"); Spacer(); Button { store.showingNewGroup = true } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }.buttonStyle(.plain).foregroundStyle(.secondary).help("New group").padding(.top, 8) }
                    ForEach(store.groups.filter { !$0.isHidden }) { group in GroupRow(group: group, botToDelete: $groupToDelete) }
                    sectionLabel("WORKSPACE")
                    Button { store.showingHiddenBots.toggle() } label: { Label("Hidden chats", systemImage: "eye.slash").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 9).frame(height: 34) }.buttonStyle(.plain)
                    if store.showingHiddenBots {
                        ForEach(store.bots.filter(\.isHidden)) { bot in row(bot) }
                        ForEach(store.groups.filter(\.isHidden)) { group in GroupRow(group: group, botToDelete: $groupToDelete) }
                    }
                }.padding(.horizontal, 8)
            }.chromeProbe("sidebar_list")
            SettingsLink {
                HStack(spacing: 9) { Image(systemName: "person.crop.circle.fill").font(.system(size: 25)).foregroundStyle(.secondary); Text("Konrad").font(.system(size: 13, weight: .medium)); Spacer() }
                    .contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }.background(AppColor.sidebar)
        .alert("Delete \(botToDelete?.name ?? "bot")?", isPresented: Binding(get: { botToDelete != nil }, set: { if !$0 { botToDelete = nil } })) {
            Button("Cancel", role: .cancel) { botToDelete = nil }
            Button("Delete", role: .destructive) { if let botToDelete { store.delete(botToDelete) }; botToDelete = nil }
        } message: { Text("Its local conversation history will be removed. This can’t be undone.") }
        .alert("Delete group \(groupToDelete?.name ?? "")?", isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } })) {
            Button("Cancel", role: .cancel) { groupToDelete = nil }
            Button("Delete", role: .destructive) { if let groupToDelete { store.deleteGroup(groupToDelete) }; groupToDelete = nil }
        } message: { Text("The group’s local transcript is removed; its bots and their own chats stay.") }
    }
    private func sectionLabel(_ value: String) -> some View { Text(value).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.top, 12).padding(.bottom, 4) }
    private func row(_ bot: Bot) -> some View { BotRow(bot: bot, selected: selection == bot && store.selectedGroup == nil, botToDelete: $botToDelete) }
}

/// A bot in the sidebar: its mark (still unless working or hovered), name and unread dot, plus the context actions.
private struct BotRow: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot; let selected: Bool; @Binding var botToDelete: Bot?
    @State private var hovering = false
    var body: some View {
        Button { store.open(bot) } label: {
            HStack(spacing: 9) {
                BotAvatar(bot: bot, size: 28, motion: .list, isWorking: store.isWorking(bot), isHovered: hovering, probe: "sidebar")
                Text(bot.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 5)
                if bot.isUnread { Circle().fill(.primary.opacity(0.72)).frame(width: 6, height: 6) }
            }.padding(.horizontal, 7).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 7)).background(selected ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            Button("Edit", systemImage: "pencil") { store.editingBot = bot }
            if !bot.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(bot) } }
            Button(bot.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: bot.isHidden ? "eye" : "eye.slash") { store.setHidden(bot, !bot.isHidden) }
            Button(bot.notificationsEnabled ? "Mute Notifications" : "Enable Notifications", systemImage: bot.notificationsEnabled ? "bell.slash" : "bell") { bot.notificationsEnabled.toggle(); store.save() }
            Divider(); Button("Delete", systemImage: "trash", role: .destructive) { botToDelete = bot }
        }
    }
}

/// A group in the sidebar: stacked member avatars, name, unread dot and the same context actions as a bot.
private struct GroupRow: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var group: GroupChat; @Binding var botToDelete: GroupChat?
    @State private var hovering = false
    var body: some View {
        let selected = store.selectedGroup?.id == group.id
        Button { store.open(group) } label: {
            HStack(spacing: 9) {
                GroupAvatarStack(group: group, members: store.members(of: group), size: 28, isHovered: hovering,
                                 halo: selected ? AppColor.selection : AppColor.sidebar, probe: "group:\(group.id)")
                Text(group.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 5)
                if group.isMuted { Image(systemName: "bell.slash").font(.system(size: 9)).foregroundStyle(.tertiary) }
                if group.isUnread { Circle().fill(.primary.opacity(0.72)).frame(width: 6, height: 6) }
            }.padding(.horizontal, 7).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 7))
                .background(selected ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }.buttonStyle(.plain).contextMenu {
            if !group.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(group) } }
            Button(group.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: group.isHidden ? "eye" : "eye.slash") { store.setHidden(group, !group.isHidden) }
            Button(group.isMuted ? "Enable Notifications" : "Mute Notifications", systemImage: group.isMuted ? "bell" : "bell.slash") { group.isMuted.toggle(); store.save() }
            Divider(); Button("Delete Group", systemImage: "trash", role: .destructive) { botToDelete = group }
        }
    }
}

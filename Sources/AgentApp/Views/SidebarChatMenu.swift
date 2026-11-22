import SwiftUI

/// The one context menu of a sidebar chat, shared by a bot's row, a group's row and a pinned tile: everything a row
/// offers, plus Pin and Move to Section. `askNewSection` opens the name prompt with this chat to put in the new section;
/// `requestDelete` opens the delete confirmation the sidebar owns.
struct SidebarChatMenu: View {
    @EnvironmentObject private var store: AppStore
    let chat: SidebarChat
    let askNewSection: (UUID?) -> Void
    let requestDelete: () -> Void

    var body: some View {
        switch chat {
        case .bot(let bot):
            Button("Edit", systemImage: "pencil") { store.editingBot = bot }
            if !bot.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(bot) } }
            Button(bot.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: bot.isHidden ? "eye" : "eye.slash") { store.setHidden(bot, !bot.isHidden) }
            Button(bot.notificationsEnabled ? "Mute Notifications" : "Enable Notifications", systemImage: bot.notificationsEnabled ? "bell.slash" : "bell") { bot.notificationsEnabled.toggle(); store.save() }
        case .group(let group):
            if !group.isUnread { Button("Mark as Unread", systemImage: "circle.fill") { store.markUnread(group) } }
            Button(group.isHidden ? "Show in Sidebar" : "Hide from Sidebar", systemImage: group.isHidden ? "eye" : "eye.slash") { store.setHidden(group, !group.isHidden) }
            Button(group.isMuted ? "Enable Notifications" : "Mute Notifications", systemImage: group.isMuted ? "bell" : "bell.slash") { group.isMuted.toggle(); store.save() }
        }
        Divider()
        if store.isPinned(chat.id) {
            Button("Unpin", systemImage: "pin.slash") { store.setPinned(chat.id, false) }
        } else {
            Button("Pin", systemImage: "pin") { store.setPinned(chat.id, true) }.disabled(!store.canPinMore)
        }
        moveMenu
        Divider()
        switch chat {
        case .bot: Button("Delete", systemImage: "trash", role: .destructive) { requestDelete() }
        case .group: Button("Delete Group", systemImage: "trash", role: .destructive) { requestDelete() }
        }
    }

    /// "Move to Section": each section with a tick on the current one, Unsectioned, and a new one.
    private var moveMenu: some View {
        let current: UUID? = store.sidebar.sectionID(of: chat.id)
        return Menu("Move to Section", systemImage: "folder") {
            ForEach(store.sidebar.sections) { section in
                Button { store.moveChat(chat.id, toSection: section.id) } label: {
                    if current == section.id { Label(section.name, systemImage: "checkmark") } else { Text(section.name) }
                }
            }
            Button { store.moveChat(chat.id, toSection: nil) } label: {
                if current == nil { Label("Unsectioned", systemImage: "checkmark") } else { Text("Unsectioned") }
            }
            Divider()
            Button("New Section…", systemImage: "plus") { askNewSection(chat.id) }
        }
    }
}

import Foundation

/// Pins, named sections and folds for the sidebar. The rules live in `SidebarOrganisation`; these only guard against
/// an offered restore, change it, and save. `sidebarChats` itself stays the plain recency order.
extension AppStore {
    var showsSampleTeam: Bool {
        let visible = unhiddenChats
        return !visible.isEmpty && visible.allSatisfy { chat in
            if case .bot(let bot) = chat { return bot.sampleProfile != nil }
            return false
        }
    }

    var sidebarLayout: SidebarLayout {
        SidebarLayout.make(chats: showsSampleTeam ? unhiddenChats : sidebarChats, organisation: sidebar)
    }

    func isPinned(_ chat: UUID) -> Bool { sidebar.pinned.contains(chat) }
    var canPinMore: Bool { sidebar.canPinMore }

    /// Makes a section, with the chat in it when one is given. False for a refused name.
    @discardableResult
    func createSidebarSection(named name: String, adding chat: UUID? = nil) -> Bool {
        guard storeRestoreOffer == nil else { return false }
        guard sidebar.createSection(named: name, adding: chat) != nil else { return false }
        save(); return true
    }

    @discardableResult
    func renameSidebarSection(_ id: UUID, to name: String) -> Bool {
        guard storeRestoreOffer == nil else { return false }
        guard sidebar.renameSection(id, to: name) else { return false }
        save(); return true
    }

    /// Its chats return to Unsectioned; none is deleted.
    func deleteSidebarSection(_ id: UUID) {
        guard storeRestoreOffer == nil else { return }
        sidebar.deleteSection(id); save()
    }

    func moveSidebarSection(_ id: UUID, by offset: Int) {
        guard storeRestoreOffer == nil else { return }
        sidebar.moveSection(id, by: offset); save()
    }

    /// nil is the Unsectioned bucket.
    func setSidebarSectionCollapsed(_ id: UUID?, _ collapsed: Bool) {
        guard storeRestoreOffer == nil else { return }
        sidebar.setCollapsed(id, collapsed); save()
    }

    func moveChat(_ chat: UUID, toSection section: UUID?) {
        guard storeRestoreOffer == nil else { return }
        sidebar.moveChat(chat, toSection: section); save()
    }

    func setPinned(_ chat: UUID, _ pinned: Bool) {
        guard storeRestoreOffer == nil else { return }
        if pinned { guard sidebar.pin(chat) else { return } } else { sidebar.unpin(chat) }
        save()
    }
}

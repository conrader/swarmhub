import Foundation

extension AppStore {
    var visibleChatCount: Int { sidebarChats.count }

    /// Match sidebar order, skip hidden conversations, and wrap at either end.
    func moveChatSelection(by offset: Int) {
        let chats = sidebarChats
        let count = chats.count
        guard count > 0 else { return }
        let current = chats.firstIndex { $0.id == (selectedGroup?.id ?? selectedBot?.id) }
        open(chats[current.map { (($0 + offset) % count + count) % count } ?? (offset < 0 ? count - 1 : 0)])
    }
}

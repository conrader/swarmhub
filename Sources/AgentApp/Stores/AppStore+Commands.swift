import Foundation

extension AppStore {
    // Pinning and folding affect availability. Message recency only affects order.
    var visibleChatCount: Int { SidebarLayout.make(chats: unhiddenChats, organisation: sidebar).navigationOrder.count }

    /// Match sidebar order (pinned first, then open sections; folded rows are skipped), skip hidden conversations, and wrap at either end.
    func moveChatSelection(by offset: Int) {
        let chats = sidebarLayout.navigationOrder
        let count = chats.count
        guard count > 0 else { return }
        let current = chats.firstIndex { $0.id == (selectedGroup?.id ?? selectedBot?.id) }
        open(chats[current.map { (($0 + offset) % count + count) % count } ?? (offset < 0 ? count - 1 : 0)])
    }
}

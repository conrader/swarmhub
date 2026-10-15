import Foundation

extension AppStore {
    var visibleChatCount: Int { sidebarChats.count + sidebarBoxProfiles.count }

    /// Match sidebar order, skip hidden conversations, and wrap at either end.
    func moveChatSelection(by offset: Int) {
        let chats = sidebarChats
        let profiles = sidebarBoxProfiles
        let count = chats.count + profiles.count
        guard count > 0 else { return }
        let current: Int?
        if let selectedBoxProfile { current = profiles.firstIndex(of: selectedBoxProfile).map { chats.count + $0 } }
        else { current = chats.firstIndex { $0.id == (selectedGroup?.id ?? selectedBot?.id) } }
        let index = current.map { (($0 + offset) % count + count) % count } ?? (offset < 0 ? count - 1 : 0)
        if index < chats.count { open(chats[index]) }
        else { open(profiles[index - chats.count]) }
    }
}

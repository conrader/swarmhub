import Foundation

extension AppStore {
    var visibleChatCount: Int { bots.filter { !$0.isHidden }.count + groups.filter { !$0.isHidden }.count }

    /// Match sidebar order, skip hidden conversations, and wrap at either end.
    func moveChatSelection(by offset: Int) {
        let visibleBots = bots.filter { !$0.isHidden }
        let visibleGroups = groups.filter { !$0.isHidden }
        let count = visibleBots.count + visibleGroups.count
        guard count > 0 else { return }
        let current: Int?
        if let group = selectedGroup {
            current = visibleGroups.firstIndex { $0.id == group.id }.map { visibleBots.count + $0 }
        } else {
            current = visibleBots.firstIndex { $0.id == selectedBot?.id }
        }
        let index = current.map { (($0 + offset) % count + count) % count } ?? (offset < 0 ? count - 1 : 0)
        if index < visibleBots.count { open(visibleBots[index]) }
        else { open(visibleGroups[index - visibleBots.count]) }
    }
}

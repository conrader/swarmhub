import Foundation

/// P18 item 9: which chat is open when nothing the user chose applies. Never a hidden bot or group.
extension AppStore {
    /// UserDefaults key holding the last chat the user opened: `bot:<uuid>` or `group:<uuid>`.
    static let lastChatKey = "lastSelectedChat"

    /// The last chat the user opened if it still exists and is visible, else the first visible bot in sidebar order,
    /// else the first visible group, else nothing (the welcome state).
    func selectVisibleChat() {
        let last = defaults.string(forKey: Self.lastChatKey)
        if let bot = bots.first(where: { !$0.isHidden && last == Self.chatKey(bot: $0.id) }) { selectedBot = bot; selectedGroup = nil }
        else if let group = groups.first(where: { !$0.isHidden && last == Self.chatKey(group: $0.id) }) { selectedGroup = group; selectedBot = nil }
        else if let bot = bots.first(where: { !$0.isHidden }) { selectedBot = bot; selectedGroup = nil }
        else if let group = groups.first(where: { !$0.isHidden }) { selectedGroup = group; selectedBot = nil }
        else { selectedBot = nil; selectedGroup = nil }
    }

    /// Hides or shows a bot; hiding the open chat moves the selection to a visible one.
    func setHidden(_ bot: Bot, _ hidden: Bool) {
        bot.isHidden = hidden
        if hidden, selectedBot?.id == bot.id, selectedGroup == nil { selectVisibleChat() } else if hidden, selectedBot?.id == bot.id { selectedBot = nil }
        objectWillChange.send(); save()
    }

    func setHidden(_ group: GroupChat, _ hidden: Bool) {
        group.isHidden = hidden
        if hidden, selectedGroup?.id == group.id { selectVisibleChat() }
        objectWillChange.send(); save()
    }

    func rememberSelection(bot: Bot) { defaults.set(Self.chatKey(bot: bot.id), forKey: Self.lastChatKey) }
    func rememberSelection(group: GroupChat) { defaults.set(Self.chatKey(group: group.id), forKey: Self.lastChatKey) }
    static func chatKey(bot id: UUID) -> String { "bot:\(id.uuidString.lowercased())" }
    static func chatKey(group id: UUID) -> String { "group:\(id.uuidString.lowercased())" }
}

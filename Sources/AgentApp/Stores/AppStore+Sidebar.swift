import Foundation

/// One conversation in the sidebar's shared, most-recent-message-first list.
enum SidebarChat: Identifiable {
    case bot(Bot), group(GroupChat)

    var id: UUID {
        switch self { case .bot(let bot): bot.id; case .group(let group): group.id }
    }

    private var messageLists: [[ChatMessage]] {
        switch self {
        case .bot(let bot): [bot.messages] + bot.threads.map(\.messages)
        case .group(let group): [group.messages]
        }
    }

    /// Setup notices, empty streaming placeholders and drafts are not sent messages.
    func latestMessageDate(archive: ArchivedMessage?) -> Date {
        var latest = archive?.timestamp ?? .distantPast
        // Start at the end so older messages need only a date comparison while a reply is streaming.
        for messages in messageLists {
            for message in messages.reversed() where message.createdAt > latest && message.role != .system {
                let text = message.role == .assistant ? SwarmhubBlock.visibleText(message.content) : message.content
                if !message.attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { latest = message.createdAt }
            }
        }
        return latest
    }
}

extension AppStore {
    var sidebarChats: [SidebarChat] {
        let chats = bots.filter { !$0.isHidden }.map(SidebarChat.bot) + groups.filter { !$0.isHidden }.map(SidebarChat.group)
        // Preserve the existing order for equal timestamps and chats without any messages.
        var dated: [(index: Int, chat: SidebarChat, date: Date)] = []
        for (index, chat) in chats.enumerated() {
            dated.append((index, chat, chat.latestMessageDate(archive: grokHistory.newestVisible(for: chat.id))))
        }
        dated.sort { $0.date == $1.date ? $0.index < $1.index : $0.date > $1.date }
        return dated.map(\.chat)
    }

    func open(_ chat: SidebarChat) {
        switch chat { case .bot(let bot): open(bot); case .group(let group): open(group) }
    }
}

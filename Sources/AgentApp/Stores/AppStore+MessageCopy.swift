import Foundation

/// Picked messages copied as plain text (`MessageCopy`).
extension AppStore {
    /// Who a copied row is from: the user, SwarmHub for status lines, a group reply's member, else `botName` (the bot
    /// of a one-bot chat).
    func copyAuthor(_ message: ChatMessage, botName: String) -> String {
        if message.role == .user { return userName 
    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}
        if message.role == .system { return AppConstants.name 
    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}
        if let id = message.authorID { return bots.first { $0.id == id }?.name ?? "Removed bot" 
    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}
        return botName
    
    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}

    /// A copied row: its author, time and the text its row shows.
    func copiedMessage(_ message: ChatMessage, botName: String) -> CopiedMessage {
        let author = copyAuthor(message, botName: botName)
        let text = displayLine(message)
        return CopiedMessage(author: author, date: message.createdAt, text: MessageCopy.body(text, attachmentNames: message.attachments.map(\.name)))
    
    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}

    /// The text a notification, a reply quote or a copied row uses for a row (`SidebarFragment.line`).
    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}

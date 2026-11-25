import Foundation

/// Picked messages copied as plain text (`MessageCopy`).
extension AppStore {
    /// Who a copied row is from: the user, SwarmHub for status lines, a group reply's member, else `botName` (the bot
    /// of a one-bot chat).
    func copyAuthor(_ message: ChatMessage, botName: String) -> String {
        if message.role == .user { return userName }
        if message.role == .system { return AppConstants.name }
        if let id = message.authorID { return bots.first { $0.id == id }?.name ?? "Removed bot" }
        return botName
    }

    /// A copied row: its author, time and the text its row shows.
    func copiedMessage(_ message: ChatMessage, botName: String) -> CopiedMessage {
        let author = copyAuthor(message, botName: botName)
        let text = displayLine(message)
        return CopiedMessage(author: author, date: message.transcriptDate, text: MessageCopy.body(text, attachmentNames: message.attachments.map(\.name)))
    }

    func displayLine(_ message: ChatMessage) -> String { SidebarFragment.line(message) }
}

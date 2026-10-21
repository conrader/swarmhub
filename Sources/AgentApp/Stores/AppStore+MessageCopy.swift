import Foundation

/// Picked messages copied as plain text (`MessageCopy`).
extension AppStore {
    /// Who a copied row is from: the user, a bot-to-bot line's sender, SwarmHub for status lines, a group reply's member,
    /// else `botName` (the bot of a one-bot chat).
    func copyAuthor(_ message: ChatMessage, botName: String) -> String {
        if message.role == .user { return userName }
        if message.presentation == .botMessage, let from = message.metadata[BotMessageKey.from], !from.isEmpty { return displayName(forProfile: from) }
        if message.role == .system { return AppConstants.name }
        if let id = message.authorID { return bots.first { $0.id == id }?.name ?? "Removed bot" }
        return botName
    }

    /// A copied row: its author, time and the text its row shows (a folded row's line, never raw protocol).
    func copiedMessage(_ message: ChatMessage, botName: String, fold: TechnicalFold? = nil) -> CopiedMessage {
        let author = copyAuthor(message, botName: botName)
        // Use the conversation's fold: classifying an isolated request loses its result and whether it is still waiting.
        let text = fold?.summary ?? technicalLine(message, botName: message.role == .assistant ? author : botName)
        return CopiedMessage(author: author, date: message.createdAt, text: MessageCopy.body(text, attachmentNames: message.attachments.map(\.name)))
    }
}

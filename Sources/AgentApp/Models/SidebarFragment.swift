import Combine
import Foundation

/// P20: the grey second line of a sidebar row, from the local store only (never the server).
/// Order: unsent composer text ("Draft: …"), the running reply's phase, the newest visible live message,
/// the newest line of the Grok archive, else "" (the empty line keeps rows even).
enum SidebarFragment {
    /// Only the head of a long message is cleaned; the row shows one truncated line anyway.
    static let scanLimit = 400

    /// `author` is set for group chats only: it names the bot that wrote a live reply ("<Member>: …"), and archived
    /// lines then use their own author. One-bot chats show the bot's lines bare.
    /// `working`: the running reply's Thinking, Typing or Working line.
    static func text(messages: [ChatMessage], draft: String?, isWorking: Bool, archiveNewest: @autoclosure () -> ArchivedMessage?,
                     author: ((UUID?) -> String?)? = nil, working: String? = nil) -> String {
        if let draft, case let value = plain(draft), !value.isEmpty { return "Draft: " + value }
        if isWorking { return working ?? ChatActivityPhase.thinking.label }
        for message in messages.reversed() where message.role != .system {
            let body = plain(message.role == .assistant ? SwarmhubBlock.visibleText(message.content) : message.content)
            let value = body.isEmpty ? (message.attachments.first.map { "Attachment: " + $0.name } ?? "") : body
            guard !value.isEmpty else { continue }
            return prefixed(value, isUser: message.role == .user, author: message.role == .assistant ? author?(message.authorID) : nil)
        }
        if let line = archiveNewest(), case let value = plain(line.text), !value.isEmpty {
            return prefixed(value, isUser: line.role == "user", author: author == nil ? nil : line.author)
        }
        return ""
    }

    private static func prefixed(_ value: String, isUser: Bool, author: String?) -> String {
        if isUser { return "You: " + value }
        if let author, !author.isEmpty { return author + ": " + value }
        return value
    }

    /// Markdown reduced to plain text with whitespace collapsed to single spaces.
    static func plain(_ markdown: String) -> String {
        var text = String(markdown.prefix(scanLimit))
        let rules: [(String, String)] = [
            (#"```[^\n]*"#, " "),                       // code fence lines (language tag included)
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),          // images → alt text
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),           // links → label
            (#"(?m)^\s{0,3}#{1,6}\s+"#, ""),             // headings
            (#"(?m)^\s{0,3}>\s?"#, ""),                  // block quotes
            (#"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, ""),      // list markers
            (#"(\*\*|__|~~)(.+?)\1"#, "$2"),             // bold, strikethrough
            (#"(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])"#, "$1"), // *italic*
            (#"(?<!\w)_(?!\s)([^_\n]+?)_(?!\w)"#, "$1"),          // _italic_
            (#"`([^`]*)`"#, "$1"),                       // inline code
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Unsent composer text per chat (bot or group id), shared by the composers and the sidebar's "Draft:" line.
/// Its own object so typing re-renders the composer and the sidebar, not every view observing the store.
@MainActor final class ComposerDrafts: ObservableObject {
    @Published private(set) var texts: [UUID: String] = [:]
    func text(for id: UUID) -> String { texts[id] ?? "" }
    func set(_ value: String, for id: UUID) {
        guard texts[id, default: ""] != value else { return }
        texts[id] = value.isEmpty ? nil : value
    }
}

import Foundation

/// Anything the composer can send into: the bot's main chat or one of its threads.
protocol Conversation: AnyObject {
    var messages: [ChatMessage] { get set }
    var hermesSessionID: String? { get set }
}

extension Bot: Conversation {
    var isUnread: Bool { unreadCount > 0 || manualUnread }
    func thread(for messageID: UUID) -> ChatThread? { threads.first { $0.parentMessageID == messageID } }
}

/// A threaded reply: a Hermes fork (`POST /api/sessions/{id}/fork`) of the bot's session, shown nested
/// under the message it was started from. Hermes copies the whole source transcript into the fork, so
/// the thread's server context is the chat as it stood when the thread was opened.
final class ChatThread: ObservableObject, Identifiable, Codable, Conversation {
    let id: UUID; let parentMessageID: UUID; let parentSessionID: String?; let createdAt: Date
    @Published var hermesSessionID: String?; @Published var messages: [ChatMessage]
    init(id: UUID = UUID(), parentMessageID: UUID, parentSessionID: String?, hermesSessionID: String?, messages: [ChatMessage] = [], createdAt: Date = .now) {
        self.id = id; self.parentMessageID = parentMessageID; self.parentSessionID = parentSessionID
        self.hermesSessionID = hermesSessionID; self.messages = messages; self.createdAt = createdAt
    }
    var replyCount: Int { messages.filter { $0.role != .system && !$0.content.isEmpty }.count }
    enum CodingKeys: CodingKey { case id, parentMessageID, parentSessionID, createdAt, hermesSessionID, messages }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); parentMessageID = try c.decode(UUID.self, forKey: .parentMessageID)
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID); createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        hermesSessionID = try c.decodeIfPresent(String.self, forKey: .hermesSessionID); messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(parentMessageID, forKey: .parentMessageID); try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encode(createdAt, forKey: .createdAt); try c.encodeIfPresent(hermesSessionID, forKey: .hermesSessionID); try c.encode(messages, forKey: .messages)
    }
}

/// A file attached to a user message. Images are stored downscaled in `attachments/` next to store.json;
/// small text files are kept inline because they are sent as a fenced block anyway.
struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text }
    let id: UUID; let kind: Kind; let name: String; let mimeType: String; let byteCount: Int
    var fileName: String? = nil; var text: String? = nil
}

extension ChatMessage {
    /// Steer bubbles were sent to a running turn, not as a turn of their own.
    var isSteer: Bool { metadata["steer"] != nil }
    /// The text Hermes receives for this message: typed text plus inline text files.
    var outgoingText: String { AttachmentEncoder.compose(text: content, attachments: attachments) }
}

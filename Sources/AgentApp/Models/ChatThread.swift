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
    /// P13: the role a thread was opened for and the lock the app recorded on its fork (Part D sets them).
    var role: ModelRole?; var modelLock: HermesModelLock?
    init(id: UUID = UUID(), parentMessageID: UUID, parentSessionID: String?, hermesSessionID: String?, messages: [ChatMessage] = [], createdAt: Date = .now) {
        self.id = id; self.parentMessageID = parentMessageID; self.parentSessionID = parentSessionID
        self.hermesSessionID = hermesSessionID; self.messages = messages; self.createdAt = createdAt
    }
    var replyCount: Int { messages.filter { $0.role != .system && !$0.content.isEmpty }.count }
    enum CodingKeys: CodingKey { case id, parentMessageID, parentSessionID, createdAt, hermesSessionID, messages, role, modelLock }
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); parentMessageID = try c.decode(UUID.self, forKey: .parentMessageID)
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID); createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        hermesSessionID = try c.decodeIfPresent(String.self, forKey: .hermesSessionID); messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        role = (try? c.decodeIfPresent(ModelRole.self, forKey: .role)) ?? nil; modelLock = (try? c.decodeIfPresent(HermesModelLock.self, forKey: .modelLock)) ?? nil
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(parentMessageID, forKey: .parentMessageID); try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encode(createdAt, forKey: .createdAt); try c.encodeIfPresent(hermesSessionID, forKey: .hermesSessionID); try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(role, forKey: .role); try c.encodeIfPresent(modelLock, forKey: .modelLock)
    }
}

/// A file attached to a user message. Images are stored downscaled in `attachments/` next to store.json;
/// small text files are kept inline because they are sent as a fenced block anyway. P19: a PDF, RTF, DOC
/// or DOCX is a `.text` attachment with its document MIME type, the text read on the Mac, its page count
/// and a one-line summary (no new `Kind`, so older builds still decode it).
struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text }
    let id: UUID; let kind: Kind; let name: String; let mimeType: String; let byteCount: Int
    var fileName: String? = nil; var text: String? = nil
    var pageCount: Int? = nil; var summary: String? = nil
}

extension ChatAttachment {
    enum CodingKeys: String, CodingKey { case id, kind, name, mimeType, byteCount, fileName, text, pageCount, summary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(Kind.self, forKey: .kind); name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decode(String.self, forKey: .mimeType); byteCount = try c.decode(Int.self, forKey: .byteCount)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName); text = try c.decodeIfPresent(String.self, forKey: .text)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount); summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    /// Documents read on the Mac (PDF, RTF, DOC, DOCX), told apart from plain text files by MIME type.
    var isDocument: Bool { kind == .text && DocumentKind(mimeType: mimeType) != nil }
    /// "12 pages" for a PDF, else the format ("DOCX").
    var documentLabel: String? {
        guard let document = DocumentKind(mimeType: mimeType) else { return nil }
        if let pageCount { return pageCount == 1 ? "1 page" : "\(pageCount) pages" }
        return document.label
    }
}

extension ChatMessage {
    /// Steer bubbles were sent to a running turn, not as a turn of their own.
    var isSteer: Bool { metadata["steer"] != nil }
    /// The text Hermes receives for this message: typed text plus inline text files.
    var outgoingText: String { AttachmentEncoder.compose(text: content, attachments: attachments) }
}

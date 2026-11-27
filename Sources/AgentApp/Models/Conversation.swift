import Foundation

/// Anything the composer can send into: a bot's chat or a group.
protocol Conversation: AnyObject {
    /// The key of the conversation's turn slot (a bot's chat uses the bot's id).
    var id: UUID { get }
    var messages: [ChatMessage] { get set }
    var sessionID: String? { get set }
}

extension Bot: Conversation {
    var isUnread: Bool { unreadCount > 0 || manualUnread }
}

/// A file attached to a user message. Images are stored downscaled in `attachments/` next to store.json;
/// small text files are kept inline because they are sent as a fenced block anyway. P19: a PDF, RTF, DOC
/// or DOCX is a `.text` attachment with its document MIME type, the text read on the Mac, its page count
/// and a one-line summary (no new `Kind`, so older builds still decode it).
struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, text, video }
    let id: UUID; let kind: Kind; let name: String; let mimeType: String; let byteCount: Int
    var fileName: String? = nil; var text: String? = nil
    var pageCount: Int? = nil; var summary: String? = nil
    /// P38: the saved document this attachment was taken from (its readers are checked before every send).
    var sourceArtifactID: UUID? = nil
}

extension ChatAttachment {
    enum CodingKeys: String, CodingKey { case id, kind, name, mimeType, byteCount, fileName, text, pageCount, summary, sourceArtifactID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(Kind.self, forKey: .kind); name = try c.decode(String.self, forKey: .name)
        mimeType = try c.decode(String.self, forKey: .mimeType); byteCount = try c.decode(Int.self, forKey: .byteCount)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName); text = try c.decodeIfPresent(String.self, forKey: .text)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount); summary = try c.decodeIfPresent(String.self, forKey: .summary)
        sourceArtifactID = try c.decodeIfPresent(UUID.self, forKey: .sourceArtifactID)
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

enum ChoiceReply {
    static let cardKey = "answeredChoiceKey"
    static let quoteKey = "answeredChoiceQuote"

    static func isYesNo(_ options: [String]) -> Bool {
        // “Other” opens the same free-text field as the implicit Other button.
        let labels = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return Set(labels.filter { $0 != "other" }) == ["yes", "no"]
    }
}

extension ChatMessage {
    var isDraftApproval: Bool {
        guard let key = metadata[ChoiceReply.cardKey] else { return false }
        return key.hasPrefix("draftSent.") || key.hasPrefix("pageReview.")
    }

    var displayedChoiceQuote: String? {
        guard let quote = metadata[ChoiceReply.quoteKey] else { return nil }
        guard metadata[ChoiceReply.cardKey]?.hasPrefix("pageReview.") == true,
              let draft = try? JSONDecoder().decode(PageDraft.self, from: Data(quote.utf8)) else { return quote }
        return draft.quotedText
    }

    /// A historical card keeps its quote on the user row so queue recovery and retries
    /// send the same question even if the agent has since moved on.
    var modelText: String {
        if role == .user, let request = metadata[GoalKey.request] { return request }
        guard role == .user, let quote = metadata[ChoiceReply.quoteKey] else { return content }
        return "In reply to “\(quote)”\n\(content)"
    }

    /// Steer bubbles were sent to a running turn, not as a turn of their own.
    var isSteer: Bool { metadata[SteerKey.steer] != nil }
    /// P28: a correction sent as its own message after the answer was stopped (a turn of its own, unlike a steer).
    var isCorrection: Bool { metadata[SteerKey.correction] != nil }
    /// The text the agent receives for this message: typed text plus inline text files; a correction carries its lead line.
    var outgoingText: String {
        let text = AttachmentEncoder.compose(text: modelText, attachments: attachments)
        return isCorrection ? SteerCopy.lead + "\n" + text : text
    }
}

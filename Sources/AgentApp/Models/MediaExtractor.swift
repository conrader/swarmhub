import Foundation

/// One entry of the Media tab: an attachment, an image or a link found in a bot's transcripts.
struct MediaItem: Identifiable, Equatable {
    enum Kind: String, Equatable { case image, file, link }
    let id: String; let kind: Kind; let title: String
    /// Remote/data URL for links and Markdown images; nil for stored attachments.
    let url: String?
    let attachment: ChatAttachment?
    let messageID: UUID; let threadID: UUID?; let date: Date
}

enum MediaExtractor {
    /// Main chat and threads together, newest first.
    static func items(in bot: Bot) -> [MediaItem] {
        let all = items(in: bot.messages, threadID: nil) + bot.threads.flatMap { items(in: $0.messages, threadID: $0.id) }
        return all.enumerated().sorted { lhs, rhs in
            lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset > rhs.offset
        }.map(\.element)
    }

    static func items(in messages: [ChatMessage], threadID: UUID?) -> [MediaItem] {
        messages.flatMap { message -> [MediaItem] in
            var found: [(MediaItem.Kind, String, String?, ChatAttachment?)] = []
            for attachment in message.attachments { found.append((attachment.kind == .image ? .image : .file, attachment.name, nil, attachment)) }
            switch message.presentation {
            case .text where message.role != .system:
                for image in ChatCardParser.markdownImages(in: message.content) {
                    found.append((.image, image.alt.isEmpty ? (image.url.hasPrefix("data:") ? "Image" : ChatCardParser.pillLabel(image.url)) : image.alt, image.url, nil))
                }
                for link in ChatCardParser.links(in: message.content) { found.append((.link, ChatCardParser.pillLabel(link), link, nil)) }
            default: break
            }
            return found.enumerated().map { index, item in
                MediaItem(id: "\(message.id.uuidString)-\(index)", kind: item.0, title: item.1, url: item.2, attachment: item.3, messageID: message.id, threadID: threadID, date: message.createdAt)
            }
        }
    }
}

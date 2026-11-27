import Foundation

/// One entry of the Media tab: an attachment, an image or a link found in a bot's transcripts.
struct MediaItem: Identifiable, Equatable {
    enum Kind: String, Equatable { case image, video, file, link }
    let id: String; let kind: Kind; let title: String
    /// Remote/data URL for links and Markdown images; nil for stored attachments.
    let url: String?
    let attachment: ChatAttachment?
    let messageID: UUID; let date: Date
}

enum MediaExtractor {
    /// The chat's media, newest first.
    static func items(in bot: Bot) -> [MediaItem] {
        let all = items(in: bot.messages)
        return all.enumerated().sorted { lhs, rhs in
            lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset > rhs.offset
        }.map(\.element)
    }

    static func items(in messages: [ChatMessage]) -> [MediaItem] {
        messages.flatMap { message -> [MediaItem] in
            var found: [(MediaItem.Kind, String, String?, ChatAttachment?)] = []
            for attachment in message.attachments {
                let kind: MediaItem.Kind = switch attachment.kind {
                case .image: .image
                case .video: .video
                case .text: .file
                }
                found.append((kind, attachment.name, nil, attachment))
            }
            if let published = message.publishedResults?.items {
                for item in published {
                    let kind: MediaItem.Kind = switch item.kind == .file ? ChatMediaKind(filename: item.title) : nil {
                    case .image: .image
                    case .video: .video
                    default: .file
                    }
                    found.append((kind, item.title, nil, nil))
                }
            }
            switch message.presentation {
            case .text where message.role != .system:
                if message.role == .assistant {
                    let prose = TranscriptText(reply: message.content, segments: nil).parts.flatMap { $0 }.flatMap(\.prose)
                    for item in ReplyMediaLink.links(in: prose) where message.publishedResults?.items.contains(where: { $0.kind == .file && $0.title == item.url.lastPathComponent }) != true {
                        let kind: MediaItem.Kind = ChatMediaKind(filename: item.url.lastPathComponent) == .video ? .video : .image
                        found.append((kind, item.title, nil, nil))
                    }
                }
                for image in ChatCardParser.markdownImages(in: message.content) {
                    found.append((.image, image.alt.isEmpty ? (image.url.hasPrefix("data:") ? "Image" : ChatCardParser.pillLabel(image.url)) : image.alt, image.url, nil))
                }
                for link in ChatCardParser.links(in: message.content) { found.append((.link, ChatCardParser.pillLabel(link), link, nil)) }
            default: break
            }
            return found.enumerated().map { index, item in
                MediaItem(id: "\(message.id.uuidString)-\(index)", kind: item.0, title: item.1, url: item.2, attachment: item.3, messageID: message.id, date: message.createdAt)
            }
        }
    }
}

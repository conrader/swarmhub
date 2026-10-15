import SwiftUI

/// Every attachment, image and link in the bot's chat and threads, newest first; click jumps to the message.
struct MediaTabView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        let items = MediaExtractor.items(in: bot)
        VStack(alignment: .leading, spacing: 6) {
            // P38: saved documents first; the chat's images, files and links below.
            if !bot.isDemo { ArtifactLibraryView(bot: bot).padding(.bottom, 12); Text("In this chat").font(.headline) }
            if items.isEmpty { Text("Images, files and links shared in this chat will appear here.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Button { store.jump(to: item) } label: {
                        HStack(spacing: 10) {
                            thumbnail(item).frame(width: 40, height: 40).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 7)).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                                Text("\(item.kind.rawValue.capitalized)\(item.threadID != nil ? " · thread" : "") · \(item.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Show in chat")
                    if item.kind == .link, let link = item.url.flatMap(URL.init(string:)) { Button { ExternalLink.open(link) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).foregroundStyle(.secondary).help(link.absoluteString) }
                }.padding(6).background(AppColor.card, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
    @ViewBuilder private func thumbnail(_ item: MediaItem) -> some View {
        if let attachment = item.attachment, attachment.kind == .image, let url = store.attachmentURL(attachment), let image = ThumbnailCache.image(at: url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if item.kind == .image, let url = item.url {
            RemoteOrDataImage(url: url, maxWidth: 40, maxHeight: 40)
        } else {
            Image(systemName: item.kind == .link ? "link" : item.kind == .image ? "photo" : item.attachment.map { DocumentKind(mimeType: $0.mimeType) != nil } == true ? "doc.richtext" : "doc").foregroundStyle(.secondary)
        }
    }
}

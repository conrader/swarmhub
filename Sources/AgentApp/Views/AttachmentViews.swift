import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Decoded attachment images, so a streaming transcript does not reread files on every token.
@MainActor enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()
    static func image(at url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL); return image
    }
}

/// Thumbnails in a sent bubble; click to preview.
struct AttachmentThumbnails: View {
    let attachments: [ChatAttachment]
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let layout = attachments.contains { $0.kind == .video }
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            ForEach(attachments) { item in
                if item.kind == .video, let url = store.attachmentURL(item) {
                    ChatVideo(url: url).frame(maxWidth: 420).frame(height: 208).accessibilityLabel(item.name)
                } else { AttachmentTile(attachment: item, size: 120) }
            }
        }
    }
}

struct AttachmentTile: View {
    @EnvironmentObject private var store: AppStore
    let attachment: ChatAttachment; let size: CGFloat; var remove: (() -> Void)? = nil
    @State private var previewing = false
    var body: some View {
        Button { previewing = true } label: { tile }.buttonStyle(.plain).accessibilityLabel("Preview " + attachment.name).help(attachment.summary.map { "\(attachment.name)\n\($0)" } ?? attachment.name)
            .overlay(alignment: .topTrailing) {
                if let remove { Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary).background(Circle().fill(AppColor.chat)) }.buttonStyle(.plain).padding(3).help("Remove") }
            }
            .sheet(isPresented: $previewing) { ImagePreviewSheet(title: attachment.name) { preview } }
    }
    @ViewBuilder private var tile: some View {
        if attachment.kind == .image, let url = store.attachmentURL(attachment), let image = ThumbnailCache.image(at: url) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size * 0.75).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.separator, lineWidth: 0.5))
        } else {
            HStack(spacing: 7) {
                Image(systemName: AttachmentPreview.symbol(for: attachment)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1)
                    Text(([attachment.documentLabel].compactMap { $0 } + [ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)]).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let summary = attachment.summary { Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: 220, alignment: .leading)
                .background(AppColor.card, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColor.separator, lineWidth: 0.5))
        }
    }
    @ViewBuilder private var preview: some View {
        if attachment.kind == .image, let url = store.attachmentURL(attachment), let image = ThumbnailCache.image(at: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1000, maxHeight: 760)
        } else if attachment.kind == .video, let url = store.attachmentURL(attachment) {
            ChatVideo(url: url).frame(width: 640, height: 360)
        } else {
            let shown = AttachmentPreview.capped(attachment.text ?? "")
            VStack(alignment: .leading, spacing: 8) {
                if let note = shown.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                ScrollView { Text(shown.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }
            }.frame(width: 720, height: 520)
        }
    }
}

/// P19: document chips and the text preview (the full text is still what is sent).
enum AttachmentPreview {
    static let maxPreviewCharacters = 20_000
    static func symbol(for attachment: ChatAttachment) -> String {
        if attachment.kind == .video { return "film" }
        return attachment.kind == .image || attachment.mimeType.hasPrefix("image/") ? "photo" : DocumentKind(mimeType: attachment.mimeType) != nil ? "doc.richtext" : "doc.text"
    }
    static func capped(_ text: String) -> (text: String, note: String?) {
        let count = text.count
        guard count > maxPreviewCharacters else { return (text, nil) }
        return (String(text.prefix(maxPreviewCharacters)), "Showing the first 20,000 of \(count.formatted(.number.locale(Locale(identifier: "en_US")))) characters.")
    }
}

struct ImagePreviewSheet<Content: View>: View {
    let title: String; @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline).lineLimit(1); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
            Divider()
            content().padding(14)
        }.background(AppColor.panel)
    }
}

/// Cmd+V in the composer: files and images on the pasteboard become attachments; text pastes normally.
enum PasteboardAttachments {
    struct Image { let data: Data; let name: String }
    enum Item { case files([URL]), images([Image]) }

    static func item(from pasteboard: NSPasteboard = .general) -> Item? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return item(files: urls, items: pasteboard.pasteboardItems ?? [])
    }

    static func item(files: [URL], items: [NSPasteboardItem]) -> Item? {
        if !files.isEmpty { return .files(files) }
        let images = items.compactMap(image(from:))
        return images.isEmpty ? nil : .images(images)
    }

    private static func image(from item: NSPasteboardItem) -> Image? {
        // An image may also carry a text caption or source URL. Pick one image representation per item.
        for type in [UTType.png, .jpeg, .gif, .webP] {
            if let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)),
               let ext = type.preferredFilenameExtension {
                return Image(data: data, name: "Pasted image." + ext)
            }
        }
        if let tiff = item.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return Image(data: png, name: "Pasted image.png")
        }
        return nil
    }
}

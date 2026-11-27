import SwiftUI

struct ReplyMediaPreview: View {
    let link: ReplyMediaLink
    let messageID: UUID
    let isLocal: Bool
    var inGallery = false
    var expanded = false
    let open: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var file: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let file {
                if ChatMediaKind(filename: link.url.lastPathComponent) == .video {
                    ChatVideo(url: file).frame(maxWidth: expanded ? 900 : 420).frame(height: expanded ? 440 : 208)
                        .accessibilityLabel(link.title)
                } else if let image = ThumbnailCache.image(at: file) {
                    let picture = Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: expanded ? 1000 : inGallery ? 190 : 420, maxHeight: expanded ? 760 : inGallery ? 165 : 300, alignment: .leading)
                    if expanded { picture }
                    else { Button(action: open) { picture }.buttonStyle(.plain).accessibilityLabel("Preview " + link.title) }
                } else { Text("Image preview unavailable.") }
            } else if let error {
                Label(link.url.lastPathComponent + " · " + error, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
            } else { ProgressView("Loading preview…").controlSize(.small) }
        }
        .task(id: isLocal) {
            file = nil
            error = nil
            guard isLocal else { error = "Ask the bot to publish this file from its workspace."; return }
            do {
                let cached = try await PublishedMediaCache.shared.localFile(link.url, message: messageID, storeURL: store.fileURL)
                try Task.checkCancellation()
                file = cached
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

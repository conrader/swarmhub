import SwiftUI
import Quartz

struct HerdrReplyFiles: View {
    let results: HerdrReplyResults
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(results.items) { item in
                PublishedResultRow(serverID: results.serverID, item: item)
            }
        }.id(results.serverID)
    }
}

private final class PublishedLocalFile {
    let url: URL

    init(data: Data, title: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = (title as NSString).lastPathComponent
        url = directory.appendingPathComponent(name.isEmpty || name.hasPrefix(".") || name == "/" ? "Published file" : name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

private struct PublishedResultRow: View {
    @EnvironmentObject private var store: AppStore
    let serverID: String
    let item: HerdrPublishedResult
    @State private var file: PublishedLocalFile?
    @State private var error: String?
    @State private var showing = false
    @State private var retry = 0

    private var kind: ChatMediaKind? { item.kind == .file ? ChatMediaKind(filename: item.title) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let kind {
                if let file {
                    switch kind {
                    case .image:
                        if let image = ThumbnailCache.image(at: file.url) {
                            Button { showing = true } label: {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 420, maxHeight: 300)
                            }.buttonStyle(.plain).accessibilityLabel(item.title)
                        } else { Text("Image preview unavailable.").font(.caption) }
                    case .video:
                        ChatVideo(url: file.url).frame(maxWidth: 420).frame(height: 208).accessibilityLabel(item.title)
                    }
                } else if let error {
                    Text(error).font(.caption)
                    Button("Retry preview") { retry += 1 }
                } else { ProgressView("Loading preview…").controlSize(.small) }
            }
            Button { showing = true } label: {
                Label("Open \(item.title)", systemImage: item.kind == .page ? "doc.richtext" : kind == .video ? "film" : kind == .image ? "photo" : "paperclip")
            }
        }
        .task(id: retry) {
            guard kind != nil, file == nil else { return }
            error = nil
            do {
                guard let server = store.herdrServer(id: serverID) else { throw BackendError.unavailable("The server that published this result is no longer configured.") }
                let data = try await store.herdrClient(for: server).publishedFile(id: item.id)
                try Task.checkCancellation()
                file = try PublishedLocalFile(data: data, title: item.title)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .sheet(isPresented: $showing) { HerdrResultSheet(serverID: serverID, item: item, preview: file) }
    }
}

private struct HerdrResultSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let serverID: String
    let item: HerdrPublishedResult
    let preview: PublishedLocalFile?
    @State private var downloaded: PublishedLocalFile?
    private var file: URL? { (preview ?? downloaded)?.url }
    @State private var page: HerdrClient.PublishedPage?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(page?.title ?? item.title).font(.headline)
                Spacer()
                if let file { Button("Save a copy…") { save(file) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(error).foregroundStyle(AppColor.caution).textSelection(.enabled) }
            if let file { HerdrFilePreview(url: file) }
            else if let page {
                ScrollView { ProseBlock(text: page.markdown).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            } else if error == nil { ProgressView("Opening…") }
            Spacer(minLength: 0)
        }.padding().frame(minWidth: 480, idealWidth: 640, minHeight: 360, idealHeight: 480)
        .task { await load() }

    }

    private func load() async {
        guard file == nil else { return }
        do {
            guard let server = store.herdrServer(id: serverID) else { throw BackendError.unavailable("The server that published this result is no longer configured.") }
            let client = try store.herdrClient(for: server)
            if let id = item.pageID, item.kind == .page {
                page = try await client.publishedPage(id: id, revision: item.revision)
            } else {
                let data = try await client.publishedFile(id: item.id)
                try Task.checkCancellation()
                downloaded = try PublishedLocalFile(data: data, title: item.title)
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func save(_ file: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: file).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}

private struct HerdrFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {}
}

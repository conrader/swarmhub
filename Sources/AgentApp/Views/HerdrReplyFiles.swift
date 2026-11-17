import SwiftUI
import Quartz

struct HerdrReplyFiles: View {
    let results: HerdrReplyResults
    @State private var selected: HerdrPublishedResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(results.items) { item in
                Button { selected = item } label: {
                    Label("Open \(item.title)", systemImage: item.kind == .page ? "doc.richtext" : "paperclip")
                }
            }
        }.sheet(item: $selected) { item in HerdrResultSheet(serverID: results.serverID, item: item) }
    }
}

private struct HerdrResultSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let serverID: String
    let item: HerdrPublishedResult
    @State private var file: URL?
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
        .onDisappear { if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) } }
    }

    private func load() async {
        do {
            guard let server = store.herdrServer(id: serverID) else { throw BackendError.unavailable("The server that published this result is no longer configured.") }
            let client = try store.herdrClient(for: server)
            if let id = item.pageID, item.kind == .page {
                page = try await client.publishedPage(id: id, revision: item.revision)
            } else {
                let data = try await client.publishedFile(id: item.id)
                try Task.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let name = (item.title as NSString).lastPathComponent
                let safe = name.isEmpty || name.hasPrefix(".") || name == "/" ? "Published file" : name
                let url = directory.appendingPathComponent(safe)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do { try data.write(to: url, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                file = url
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

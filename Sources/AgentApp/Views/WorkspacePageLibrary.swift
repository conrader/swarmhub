import SwiftUI

struct PublishedBriefCard: View {
    let title: String
    let excerpt: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title).font(.headline)
                Spacer(minLength: 4)
                Text("Published Page").font(.caption).foregroundStyle(.secondary)
            }
            let lines = excerpt.split(whereSeparator: \.isNewline).prefix(5).map { SidebarFragment.plain(String($0)) }
            let summary = lines.first == title ? lines.dropFirst() : lines[...]
            Text(verbatim: summary.prefix(3).joined(separator: "\n")).font(.callout).lineLimit(4)
            Button("Open Page", action: open).accessibilityLabel("Open " + title)
        }
        .padding(10).frame(maxWidth: 500, alignment: .leading)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(AppColor.separator) }
    }
}

struct WorkspacePageReader: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let link: WorkspacePageLink
    @State private var page: HerdrClient.PublishedPage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(page?.title ?? link.title).font(.headline)
                    if let revision = link.revision { Text("Revision \(revision)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let page {
                ScrollView { ProseBlock(text: page.markdown).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            } else if let error {
                Text(error).foregroundStyle(AppColor.caution).textSelection(.enabled)
                Button("Retry") { retry += 1 }
            } else { ProgressView("Opening Page…") }
            Spacer(minLength: 0)
        }.padding().frame(minWidth: 480, idealWidth: 640, minHeight: 360, idealHeight: 480).background(AppColor.panel)
        .task(id: retry) {
            error = nil
            do {
                if link.serverID == SampleWorkspace.server.id,
                   let match = store.sampleBriefs.first(where: { $0.pageID == link.pageID && (link.revision == nil || link.revision == $0.revision) }),
                   let body = match.excerpt {
                    page = .init(title: match.title, markdown: body)
                    return
                }
                guard let server = store.herdrServer(id: link.serverID) else {
                    throw BackendError.unavailable("The workspace that published this Page is no longer configured.")
                }
                let result = try await store.herdrClient(for: server).publishedPage(id: link.pageID, revision: link.revision)
                try Task.checkCancellation()
                page = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct WorkspacePageLibrary: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var serverID: String
    @State var query: String
    @State private var page: WorkspacePageLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Published Pages").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Workspace", selection: $serverID) {
                if store.bots.contains(where: { $0.sampleProfile != nil && !$0.isHidden }) {
                    Text(SampleWorkspace.server.name).tag(SampleWorkspace.server.id)
                }
                ForEach(store.herdrServers) { Text($0.name).tag($0.id) }
            }
            TextField("Search Pages in this workspace", text: $query)
            if serverID == SampleWorkspace.server.id {
                if let brief = store.sampleBriefs.first, let id = brief.pageID,
                   query.isEmpty || brief.title.localizedStandardContains(query) {
                    Button(brief.title) { page = .init(serverID: serverID, pageID: id, revision: brief.revision, title: brief.title) }
                } else { Text("No matching Pages.") }
            } else if let server = store.herdrServer(id: serverID) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                WorkspacePageList(server: server, term: term) { summary in
                    page = .init(serverID: server.id, pageID: summary.id, revision: nil, title: summary.title)
                }.id(server.id).id(term)
            } else { Text("Choose a workspace to see its Pages.") }
            Spacer(minLength: 0)
        }.padding().frame(width: 520, height: 400).background(AppColor.panel)
        .sheet(item: $page) { WorkspacePageReader(link: $0) }
    }
}

private struct WorkspacePageList: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let term: String
    let open: (HerdrClient.PageSummary) -> Void
    @State private var results: [HerdrClient.PageSummary]?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(AppColor.caution).textSelection(.enabled)
                Button("Retry") { retry += 1 }
            } else if let results {
                if results.isEmpty { Text(term.isEmpty ? "No Pages published in this workspace." : "No matching Pages.").foregroundStyle(.secondary) }
                else {
                    List(results) { item in
                        Button { open(item) } label: {
                            Label(item.title, systemImage: item.pinned == true ? "pin" : "doc.richtext")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.scrollContentBackground(.hidden)
                }
            } else { ProgressView("Loading Pages…") }
        }.task(id: retry) {
            error = nil
            do {
                if !term.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
                let response = try await store.herdrClient(for: server).workspacePages(matching: term)
                try Task.checkCancellation()
                results = response
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

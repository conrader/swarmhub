import AppKit
import SwiftUI

/// P38: the Media tab's saved documents this agent may read: Read, Export…, Attach (into this chat's composer), share
/// with another agent, remove another agent's access. Removing access stops future sends; what a chat already
/// received stays in that chat.
struct ArtifactLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var records: [RuntimeArtifact] = []
    @State private var preview: RuntimeArtifact?
    @State private var previewText = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved documents").font(.headline)
            if records.isEmpty {
                Text("Documents and text files you send to \(bot.name) are saved here, so you can read, attach or share them later.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(records) { artifact in row(artifact) }
            if !records.isEmpty {
                Text("Removing access stops future sends. Content a chat already received stays in that chat.").font(.caption2).foregroundStyle(.tertiary)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task(id: "\(bot.id)|\(bot.messages.count)") { reload() }
        .sheet(item: $preview) { artifact in
            VStack(alignment: .leading, spacing: 12) {
                Text(artifact.name).font(.headline)
                ScrollView { Text(previewText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { preview = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 640, height: 480)
        }
    }

    private func row(_ artifact: RuntimeArtifact) -> some View {
        let readers = artifact.ownerBotIDs.compactMap { id in store.bots.first { $0.id == id } }
        let others = store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo && !artifact.ownerBotIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: DocumentKind(mimeType: artifact.mimeType) != nil ? "doc.richtext" : "doc.text").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name).font(.caption.weight(.medium)).lineLimit(1)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file)) · \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text("Access: " + readers.map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 10) {
                Button("Read") { perform { previewText = String(decoding: try store.artifacts().read(artifact.id, botID: bot.id), as: UTF8.self); preview = artifact } }
                Button("Export…") { export(artifact) }
                if store.selectedBot === bot, store.selectedGroup == nil, !bot.isReadOnlyArchive {
                    Button("Attach") { perform { try store.attachToComposer(artifact, botID: bot.id) } }.help("Add to the message you are writing to \(bot.name)")
                }
                if !others.isEmpty {
                    Menu("Share") { ForEach(others) { other in Button(other.name) { perform { try store.shareArtifact(artifact, with: other.id); reload() } } } }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                if readers.contains(where: { $0.id != bot.id }) {
                    Menu("Remove access") {
                        ForEach(readers.filter { $0.id != bot.id }) { other in Button(other.name) { perform { try store.revokeArtifact(artifact, from: other.id); reload() } } }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }.buttonStyle(.link).font(.caption)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); problem = nil } catch { problem = error.localizedDescription }
    }
    private func reload() { perform { records = try store.artifactList(for: bot.id) } }
    private func export(_ artifact: RuntimeArtifact) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.name.hasSuffix(".txt") ? artifact.name : artifact.name + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try store.artifacts().read(artifact.id, botID: bot.id).write(to: url, options: .atomic) }
    }
}

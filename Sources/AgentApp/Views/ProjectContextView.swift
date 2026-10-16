import SwiftUI
import SwarmHubCoordination

struct ProjectContextView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let members: [Bot]
    @State private var text = ""
    @State private var source = ""
    @State private var kind = ProjectFact.Kind.assumption
    @State private var readers = Set<UUID>()
    @State private var supersedes: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared project context").font(.headline)
            Text("Saved in SwarmHub and included only for selected readers. History and agent claims never grant permission.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(store.projectFacts.filter { $0.projectID == projectID }.sorted { $0.createdAt < $1.createdAt }) { fact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fact.text).textSelection(.enabled)
                        Text("\(fact.kind.rawValue) · \(fact.status.rawValue) · revision \(fact.revision) · \(fact.source)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Correct") { supersedes = fact.id; text = fact.text; source = fact.source; kind = fact.kind; readers = Set(fact.readers.map(\.botID)) }
                            Button("Mark disputed") { var updated = fact; updated.status = .disputed; store.saveProjectFact(updated) }
                        }.font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
            }.frame(minHeight: 100, maxHeight: 180)
            TextEditor(text: $text).frame(height: 70).border(.secondary.opacity(0.3))
            TextField("Source or originating decision", text: $source)
            Picker("Type", selection: $kind) { ForEach(ProjectFact.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Text("Readers").font(.caption)
            ForEach(members) { bot in
                Toggle(store.mentionLabel(bot), isOn: Binding(get: { readers.contains(bot.id) }, set: { if $0 { readers.insert(bot.id) } else { readers.remove(bot.id) } }))
            }
            DisclosureGroup("Import coverage") {
                ForEach(members) { bot in
                    Text("\(bot.name): \(bot.grokHistoryCount) archived messages; \(bot.importedMemories.count) memory candidates; \(bot.importedSkills.count) imported skill descriptions; \(bot.routines.count) routine records. External tool access, active jobs, and current permissions are not established by this import.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(supersedes == nil ? "Save fact" : "Save correction") {
                    let old = supersedes.flatMap { id in store.projectFacts.first { $0.id == id } }
                    let fact = ProjectFact(projectID: projectID, text: text, source: source, owner: store.userName, at: store.now(), kind: kind,
                        readers: members.filter { readers.contains($0.id) }.map(store.teamIdentity), revision: (old?.revision ?? 0) + 1, supersedes: old?.id)
                    if store.saveProjectFact(fact) { text = ""; source = ""; supersedes = nil }
                }.disabled(text.isEmpty || source.isEmpty || readers.isEmpty)
                Spacer(); Button("Done") { dismiss() }
            }
        }.padding(20).frame(width: 510).background(AppColor.chat)
    }
}

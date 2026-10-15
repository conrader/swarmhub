import AppKit
import SwiftUI

/// P38 C: saved voice conversations: keep the transcript with notes on this Mac, export it, or send a reviewed
/// instruction to the chat (or group member) the voice conversation was opened from.
struct SavedVoiceView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var voice: CodexVoiceSession
    @State private var records: [SavedVoiceConversation] = []
    @State private var selected: UUID?
    @State private var summary = ""
    @State private var recipient: UUID?
    @State private var message: String?
    var startExpanded = false
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("Save transcript & review handoff", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Transcript", selection: $selected) {
                    Text("Current voice conversation").tag(Optional<UUID>.none)
                    ForEach(records) { Text("\($0.name) · \($0.createdAt.formatted())").tag(Optional($0.id)) }
                }.onChange(of: selected) { _, _ in loadSelection() }
                TextEditor(text: $summary).font(.body).frame(height: 80)
                    .accessibilityLabel("Voice summary or instruction to send")
                Text("Review the instruction above before sending. Saved transcripts keep both speakers and the original conversation reference.").font(.caption).foregroundStyle(.secondary)
                if let value = chosen, case .group(let groupID, let botID) = value.target,
                   let group = store.groups.first(where: { $0.id == groupID }) {
                    Picker("Recipient in \(group.name)", selection: Binding(get: { recipient ?? botID }, set: { recipient = $0 })) {
                        ForEach(store.members(of: group)) { Text($0.name).tag($0.id) }
                    }
                }
                HStack {
                    Button("Save transcript & notes") { save() }.disabled(voice.isLive || voice.isBusy || chosen?.entries.isEmpty != false)
                    Button("Export…") { export() }.disabled(chosen == nil)
                    Button("Send reviewed instruction") { handoff() }.disabled(chosen?.target == nil || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice.isLive || voice.isBusy)
                }
                if chosen == nil { Text("Nothing to save yet: start a voice conversation or pick a saved transcript.").font(.caption).foregroundStyle(.secondary) }
                if let value = chosen { Text("Destination: \(value.name)").font(.caption) }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                if selected != nil, let value = chosen {
                    ScrollView { Text(value.exportText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                }
            }
        }.task { expanded = startExpanded; reload() }
    }
    private var chosen: SavedVoiceConversation? {
        if let selected { return records.first { $0.id == selected } }
        guard !voice.transcript.entries.isEmpty else { return nil }
        return .init(id: voice.transcriptID, name: voice.transcriptContextName ?? "Voice", target: voice.actionTarget,
                     contextRevision: voice.contextRevision, entries: voice.transcript.entries, summary: summary)
    }
    private func reload() { do { records = try store.savedVoice() } catch { message = error.localizedDescription } }
    private func loadSelection() { summary = chosen?.summary ?? ""; recipient = nil; message = nil }
    private func save() {
        guard var value = chosen else { return }; value.summary = summary
        do { try store.saveVoice(value); reload(); selected = value.id; message = "Transcript and notes saved on this Mac." }
        catch { message = error.localizedDescription }
    }
    private func export() {
        guard var value = chosen else { return }; value.summary = summary
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Voice transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try value.exportText.write(to: url, atomically: true, encoding: .utf8) } catch { message = error.localizedDescription }
    }
    private func handoff() {
        guard var value = chosen, var target = value.target else { return }
        if case .group(let group, let original) = target { target = .group(groupID: group, botID: recipient ?? original) }
        value.summary = summary
        do { try store.saveVoice(value) } catch { message = error.localizedDescription; return }
        if store.handoffVoice(value, text: summary, target: target) { message = "Instruction queued in \(value.name)."; reload(); selected = value.id }
        else { message = store.errorMessage ?? "The original destination is no longer available." }
    }
}

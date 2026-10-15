import SwiftUI

/// P38 D: under a delegation card: the child's transcript (when the server named its session) and Stop (a running
/// Hermes child with a named run, on a box with run control). Without a session reference it says so.
struct ChildTaskDetailView: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let task: SubAgentTask
    @State private var transcript: String?
    @State private var note: String?
    @State private var canStop = false

    var body: some View {
        HStack(spacing: 10) {
            if task.sessionID != nil { Button("Open transcript") { load() }.buttonStyle(.link) }
            else { Text("The server did not name this child's session, so its transcript cannot be opened.").foregroundStyle(.secondary) }
            if canStop { Button("Stop child") { stop() }.buttonStyle(.link) }
        }.font(.caption)
            .task(id: task.status) { canStop = await store.canStopChild(task, bot: bot) }
            .popover(isPresented: Binding(get: { transcript != nil || note != nil }, set: { if !$0 { transcript = nil; note = nil } })) {
                ScrollView { Text(note ?? transcript ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .padding(16).frame(width: 520, height: 400)
            }
    }

    private func load() {
        Task {
            do { transcript = try await store.childTranscript(task, bot: bot) } catch { note = error.localizedDescription }
        }
    }
    private func stop() {
        Task {
            do { note = try await store.stopChild(task, bot: bot); canStop = false } catch { note = error.localizedDescription }
        }
    }
}

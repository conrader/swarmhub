import SwiftUI
import SwarmHubCore

struct SessionPickerView: View {
    let agentID: String
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionSummary] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    AvailabilityNote(text: "Pick a server session to share its canonical history with desktop. New conversations have their own session; preferences and reactions are not yet synchronized.")
                    Button("Start a new conversation", systemImage: "plus.bubble") { Task { await create() } }.disabled(loading || busy || store.capabilities[agentID]?.sessions != true)
                }
                if loading { ProgressView("Loading conversations…") }
                if let error {
                    Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } }.disabled(busy) }
                }
                if !loading && sessions.isEmpty && error == nil { Text("There are no server conversations yet.").foregroundStyle(.secondary) }
                Section("Server conversations") {
                    ForEach(sessions) { session in
                        Button { Task { await choose(session.id) } } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(session.title); Text(session.id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.disabled(busy)
                    }
                }
            }.navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .task { await load() }
        }.interactiveDismissDisabled(busy)
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do { sessions = try await store.sessions(agentID) }
        catch { self.error = (error as? CoreError)?.localizedDescription ?? "Could not load the server conversations." }
    }
    private func choose(_ id: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await store.chooseSession(id, agentID: agentID); dismiss() }
        catch { self.error = error.localizedDescription }
    }
    private func create() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await store.newSession(agentID); dismiss() }
        catch { self.error = (error as? CoreError)?.localizedDescription ?? "The new conversation could not be confirmed. Check the session list before trying again." }
    }
}

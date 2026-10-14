import SwiftUI
import SwarmHubCore

struct RootView: View {
    @Environment(MobileStore.self) private var store
    @State private var showSetup = false
    var body: some View {
        @Bindable var store = store
        Group {
            if !store.booted { ProgressView("Opening SwarmHub…") }
            else if store.profiles.isEmpty { WelcomeView(showSetup: $showSetup) }
            else {
                TabView {
                    Tab("Chats", systemImage: "bubble.left.and.bubble.right") { ChatsView() }
                    Tab("Approvals", systemImage: "checkmark.shield") { ApprovalsView() }.badge(store.approvals.count)
                    Tab("Settings", systemImage: "gearshape") { SettingsView() }
                }
            }
        }
        .sheet(isPresented: $showSetup) { SetupView() }
        .alert("SwarmHub", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct WelcomeView: View {
    @Environment(MobileStore.self) private var store
    @Binding var showSetup: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("SwarmHub").font(.headline).foregroundStyle(.secondary)
            HStack(spacing: 24) { AgentMark(color: "orange", size: 44); AgentMark(size: 64); AgentMark(color: "green", size: 44) }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            Text("Your agents.\nWherever you are.").font(.largeTitle.bold())
            Text("Give them work, follow the progress, and review the next step. Your agents run on your own server.").foregroundStyle(.secondary)
            Label("Conversations and results together", systemImage: "bubble.left")
            Label("You decide what gets approved", systemImage: "checkmark.shield")
            Spacer(minLength: 16)
            Button("Connect my server") { showSetup = true }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            Button("Explore local sample agents") { store.useSamples() }.frame(maxWidth: .infinity).padding(10)
            Text("Hermes is supported. OpenClaw and hosted setup are planned.").font(.footnote).foregroundStyle(.secondary)
        }.padding(24)
    }
}

struct ChatsView: View {
    @Environment(MobileStore.self) private var store
    @State private var query = ""
    @State private var showSetup = false
    private var visibleProfiles: [AgentProfile] { store.profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            List {
                if store.demo { AvailabilityNote(text: "Local sample agents. Messages stay on this device and no server is contacted.") }
                Section("Your agents") {
                    ForEach(visibleProfiles) { profile in
                        NavigationLink(value: profile.id) {
                            HStack(spacing: 13) {
                                AgentMark(color: profile.color)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.headline)
                                    Text(preview(profile)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if store.activeAgents.contains(profile.id) { ProgressView().controlSize(.small).accessibilityLabel("Agent working") }
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section {
                    AvailabilityNote(text: "This first native build includes setup, sessions, text chat and manual approvals. Groups, routines, media, connected apps and notifications follow the development plan.")
                }
            }
            .navigationTitle("Chats").searchable(text: $query, prompt: "Find an agent")
            .toolbar { Button("Add profile", systemImage: "plus") { showSetup = true } }
            .navigationDestination(for: String.self) { id in ChatView(agentID: id) }
            .sheet(isPresented: $showSetup) { SetupView() }
        }
    }
    private func preview(_ profile: AgentProfile) -> String {
        if let turn = store.caches[profile.id]?.turn { return turn.state == .interrupted ? "Result not yet confirmed" : "Working…" }
        if let draft = store.caches[profile.id]?.draft, !draft.isEmpty { return "Draft: \(draft)" }
        return store.caches[profile.id]?.messages.last?.text ?? (profile.sessionID == nil ? "Choose a conversation" : "Open the conversation")
    }
}

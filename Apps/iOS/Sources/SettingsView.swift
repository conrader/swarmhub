import SwiftUI
import SwarmHubCore

struct SettingsView: View {
    @Environment(MobileStore.self) private var store
    @AppStorage("appearance") private var appearance = "Dark"
    @AppStorage("displayName") private var displayName = ""
    @State private var showSetup = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    ForEach(store.profiles) { profile in
                        NavigationLink { AgentDetailsView(agentID: profile.id) } label: {
                            HStack { AgentMark(color: profile.color, size: 30); VStack(alignment: .leading) { Text(profile.name); Text(store.demo ? "Local sample" : profile.address.baseURL.host ?? "Agent server").font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                    Button("Connect another profile", systemImage: "plus") { showSetup = true }
                }
                Section("Preferences") {
                    TextField("Your name", text: $displayName)
                    Picker("Appearance", selection: $appearance) { Text("Dark").tag("Dark"); Text("Light").tag("Light"); Text("System").tag("System") }
                    AvailabilityNote(text: "Notifications while the app is closed need the push relay. This foundation build refreshes history when you reopen it.")
                }
                Section("About") {
                    LabeledContent("SwarmHub for iOS", value: "Native foundation")
                    LabeledContent("Minimum iOS", value: "18.0")
                    Link("Development specification", destination: URL(string: "https://github.com/conrader/swarmhub/blob/main/docs/ios/specsheet.md")!)
                    Text("Original static agent marks. The repository contains desktop BotAvatarsKit acknowledgements; animated mobile marks follow later.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").sheet(isPresented: $showSetup) { SetupView() }
        }
    }
}

struct AgentDetailsView: View {
    let agentID: String
    @Environment(MobileStore.self) private var store
    @State private var showDisconnect = false
    @State private var error: String?
    private var profile: AgentProfile? { store.profiles.first { $0.id == agentID } }
    var body: some View {
        Form {
            if let profile {
                Section {
                    HStack(spacing: 18) { AgentMark(color: profile.color, size: 60); VStack(alignment: .leading, spacing: 6) { Text(profile.name).font(.title2.bold()); Text(store.demo ? "Local sample agent" : profile.address.profile).foregroundStyle(.secondary) } }.padding(.vertical, 8)
                }
                Section("Connection") {
                    LabeledContent("Server", value: profile.address.baseURL.host ?? "Server")
                    LabeledContent("Profile", value: profile.address.profile)
                    LabeledContent("Conversation", value: profile.sessionID == nil ? "Not selected" : "Server session selected")
                    Button("Refresh history and capabilities") { Task { await store.refresh(agentID) } }
                }
                Section {
                    feature("Native sessions", store.capabilities[agentID]?.sessions)
                    feature("Stop a run", store.capabilities[agentID]?.stop)
                    feature("Guidance while running", store.capabilities[agentID]?.steer)
                    feature("Approval decisions", store.capabilities[agentID]?.approvals)
                } header: { Text("This server supports") } footer: { Text("Server capability support does not imply every mobile control is implemented in this foundation build.") }
                Section("Next milestones") {
                    Text("Groups, routines, media, models, remote computers, connected apps, imports and manager-agent actions.").foregroundStyle(.secondary)
                }
                if !store.demo {
                    Section {
                        Button("Disconnect this profile", role: .destructive) { showDisconnect = true }
                    } footer: { Text("Removes the key and cache from this phone. Server conversations and any running work stay on your server.") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            } else { Text("This agent is no longer configured.") }
        }.navigationTitle("Agent details").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Disconnect this profile from this phone?", isPresented: $showDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { do { try await store.disconnect(agentID) } catch { self.error = "Could not remove this profile completely. Try again." } } }
            }
    }
    private func feature(_ title: String, _ supported: Bool?) -> some View {
        LabeledContent(title, value: supported == nil ? "Not checked" : supported == true ? "Available" : "Unavailable")
    }
}

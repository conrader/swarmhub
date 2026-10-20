import SwiftUI
import SwarmHubCore

struct SetupView: View {
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var profile = "default"
    @State private var key = ""
    @State private var name = ""
    @State private var checked: (ConnectionAddress, ProfileVerification)?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(store.appConfig.setupTitle).font(.title2.bold())
                    Text("Use the address, profile name and key from whoever set up your server.").foregroundStyle(.secondary)
                }
                Section {
                    TextField("https://agents.example.com", text: $address).keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    TextField("Profile name", text: $profile).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Profile key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Display name (optional)", text: $name)
                } header: { Text("Your server") } footer: {
                    Text("Add one verified profile at a time. The key is saved in iPhone Keychain only when you add the agent. A default key does not grant access to every profile.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityLabel("Connection error: \(error)") } }
                Section {
                    Button { Task { await test() } } label: {
                        HStack { Text("Test connection"); Spacer(); if busy { ProgressView() } }
                    }.disabled(busy || !store.storageReady || address.isEmpty || key.isEmpty || profile.isEmpty)
                }
                if let checked {
                    Section("Verified profile") {
                        Label(checked.1.name, systemImage: "checkmark.circle")
                        if !checked.1.capabilities.sessions { AvailabilityNote(text: "This profile is reachable but lacks the Sessions API required by this first native build.") }
                        Button("Add agent") { Task { await save() } }.disabled(busy)
                    }
                }
                Section {
                    AvailabilityNote(text: "Use HTTPS. Localhost on iPhone is the phone, not your Mac. OpenClaw and managed hosting are not available in this build.")
                }
            }
            .navigationTitle("Connect server").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .onChange(of: address) { checked = nil }
            .onChange(of: profile) { checked = nil }
            .onChange(of: key) { checked = nil }
        }.interactiveDismissDisabled(busy)
    }
    private func test() async {
        guard !busy, store.storageReady else { return }
        busy = true; error = nil; checked = nil; focused = false
        let tested = (address, profile, key)
        defer { busy = false }
        do {
            let result = try await store.verify(address: tested.0, profile: tested.1, key: tested.2)
            if tested.0 == address && tested.1 == profile && tested.2 == key { checked = result }
        } catch { self.error = (error as? CoreError)?.localizedDescription ?? "Could not reach that address. Check your connection and try again." }
    }
    private func save() async {
        guard !busy, let checked else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            try await store.add(address: checked.0, verification: checked.1, key: key, name: name)
            key = ""; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

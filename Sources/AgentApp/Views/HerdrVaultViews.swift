import SwiftUI

@MainActor
struct HerdrVaultPrompts: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var active: Prompt?

    private struct Prompt: Identifiable, Sendable {
        let server: HerdrServer
        let request: HerdrVault.Request
        var id: String { server.id + "/" + request.id }
    }

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .sheet(item: $active) { prompt in
                HerdrVaultRequestSheet(server: prompt.server, request: prompt.request) {
                    if active?.id == prompt.id { active = nil }
                }
            }
    }

    private func refresh() async {
        guard !store.isSetupPreview, store.herdrConfigured else { return }
        if let active {
            guard let server = store.herdrServer(id: active.server.id), server == active.server else {
                self.active = nil
                return
            }
            if let client = try? store.herdrClient(for: server), let requests = try? await client.vaultRequests(),
               !requests.contains(where: { $0.id == active.request.id }), self.active?.id == active.id {
                self.active = nil
            }
            return
        }
        await withTaskGroup(of: Prompt?.self) { group in
            for server in store.herdrServers {
                guard let client = try? store.herdrClient(for: server) else { continue }
                group.addTask {
                    guard let pending = try? await client.vaultRequests().first else { return nil }
                    return Prompt(server: server, request: pending)
                }
            }
            for await prompt in group {
                guard let prompt, store.herdrServer(id: prompt.server.id) == prompt.server, !Task.isCancelled else { continue }
                active = prompt
                group.cancelAll()
                break
            }
        }
    }
}

@MainActor
private struct HerdrVaultRequestSheet: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var focused: Bool
    @State private var value = ""
    @State private var saving = false
    @State private var error: String?
    let server: HerdrServer
    let request: HerdrVault.Request
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault request").font(.title2)
            Text(verbatim: "\(request.bot) requests access for one command on \(server.name).")
            Text(verbatim: request.label).font(.headline)
            Text(verbatim: request.name).font(.system(.body, design: .monospaced))
            Text(verbatim: request.description).foregroundStyle(.secondary)
            if request.needsValue {
                SecureField("Secret value", text: $value)
                    .focused($focused)
                    .disabled(saving)
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { decide(.cancel) }.keyboardShortcut(.cancelAction)
                Button(request.needsValue ? "Save" : "Allow once") {
                    decide(.save(request.needsValue ? value : nil))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(request.needsValue && value.isEmpty)
            }
            .disabled(saving)
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
        .onAppear { focused = request.needsValue }
        .onDisappear { value = "" }
    }

    private func decide(_ decision: HerdrVault.Decision) {
        guard !saving else { return }
        value = ""
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                guard store.herdrServer(id: server.id) == server else { done(); return }
                let client = try store.herdrClient(for: server)
                try await client.vaultDecide(request, decision)
                done()
            } catch let failure as HerdrClient.Failure {
                error = failure.localizedDescription
                focused = request.needsValue
            } catch {
                self.error = "Could not reach the workspace Vault."
                focused = request.needsValue
            }
        }
    }
}

@MainActor
struct HerdrVaultSettings: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: String?
    @State private var listing: HerdrVault.Listing?
    @State private var error: String?
    @State private var edit: Edit?

    private enum Edit: Identifiable {
        case add, rename(HerdrVault.Entry), remove(HerdrVault.Entry)

        var id: String {
            switch self {
            case .add: "add"
            case .rename(let entry): "rename/" + entry.id
            case .remove(let entry): "remove/" + entry.id
            }
        }
    }

    private var server: HerdrServer? {
        store.herdrServer(id: selectedID) ?? store.herdrServers.first
    }

    var body: some View {
        Form {
            Picker("Workspace", selection: Binding(get: { server?.id ?? "" }, set: { selectedID = $0 })) {
                ForEach(store.herdrServers) { item in Text(item.name).tag(item.id) }
            }
            Section("Saved secrets") {
                if let listing {
                    if !listing.configured {
                        Text("Configure a Vault key on this workspace host.").foregroundStyle(.secondary)
                    } else {
                        if listing.entries.isEmpty { Text("No secrets saved.").foregroundStyle(.secondary) }
                        ForEach(listing.entries) { entry in
                            HStack {
                                Text(verbatim: entry.name)
                                Spacer()
                                Button("Rename") { edit = .rename(entry) }
                                Button("Delete", role: .destructive) { edit = .remove(entry) }
                            }
                        }
                        Button("Add secret") { edit = .add }
                    }
                } else if error == nil {
                    ProgressView()
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                Button("Refresh") {
                    if let server { Task { await refresh(server) } }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: server) {
            listing = nil
            error = nil
            if let server { await refresh(server) }
        }
        .sheet(item: $edit) { edit in
            if let server {
                switch edit {
                case .add:
                    HerdrVaultEntrySheet(title: "Add secret", action: "Save", name: "", enterValue: true) { name, value in
                        try await mutate(server) { try await $0.vaultAdd(name: name, value: value) }
                    }
                case .rename(let entry):
                    HerdrVaultEntrySheet(title: "Rename secret", action: "Rename", name: entry.name) { name, _ in
                        try await mutate(server) { try await $0.vaultRename(entry, name: name) }
                    }
                case .remove(let entry):
                    HerdrVaultEntrySheet(title: "Delete secret", action: "Delete", name: entry.name, deleting: true) { _, _ in
                        try await mutate(server) { try await $0.vaultRemove(entry) }
                    }
                }
            }
        }
    }

    private func refresh(_ workspace: HerdrServer) async {
        do {
            let client = try store.herdrClient(for: workspace)
            let result = try await client.vaultListing()
            guard !Task.isCancelled, server == workspace else { return }
            listing = result
            error = nil
        } catch {
            guard !Task.isCancelled, server == workspace else { return }
            listing = nil
            self.error = error.localizedDescription
        }
    }

    private func mutate(_ workspace: HerdrServer, action: (HerdrClient) async throws -> Void) async throws {
        guard server == workspace else { throw HerdrClient.Failure.invalidURL }
        try await action(store.herdrClient(for: workspace))
        await refresh(workspace)
    }
}

@MainActor
private struct HerdrVaultEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    let title: String
    let action: String
    let enterValue: Bool
    let deleting: Bool
    let commit: (String, String) async throws -> Void

    init(title: String, action: String, name: String, enterValue: Bool = false, deleting: Bool = false,
         commit: @escaping (String, String) async throws -> Void) {
        self.title = title
        self.action = action
        self._name = State(initialValue: name)
        self.enterValue = enterValue
        self.deleting = deleting
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2)
            if deleting {
                Text(verbatim: name)
                Text("This removes the secret and revokes any unused approvals for it.")
            } else {
                TextField("Name", text: $name).disabled(busy)
                if enterValue { SecureField("Secret value", text: $value).disabled(busy) }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if deleting {
                    Button(action, role: .destructive) { save() }
                } else {
                    Button(action) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (enterValue && value.isEmpty))
                }
            }
            .disabled(busy)
        }
        .padding(24)
        .frame(width: 400)
        .interactiveDismissDisabled(busy)
        .onDisappear { value = "" }
    }

    private func save() {
        guard !busy else { return }
        let submittedName = name
        let submittedValue = value
        value = ""
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await commit(submittedName, submittedValue)
                dismiss()
            } catch let failure as HerdrClient.Failure {
                error = failure.localizedDescription
            } catch {
                self.error = "Could not reach the workspace Vault."
            }
        }
    }
}

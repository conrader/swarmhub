import AppKit
import SwiftUI

@MainActor
struct HerdrVaultPrompts: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var window = WindowReference()
    @State private var pending: [String: [Prompt]] = [:]
    @State private var resolved: [String: Set<String>] = [:]
    @State private var active: Prompt?
    @State private var presentedID: String?
    let anotherSheet: Bool

    init(anotherSheet: Bool) { self.anotherSheet = anotherSheet }

    private struct Prompt: Identifiable, Sendable {
        let server: HerdrServer
        let request: HerdrVault.Request
        var id: String { server.id + "/" + request.id }
    }

    private final class WindowReference {
        weak var value: NSWindow?
    }

    func body(content: Content) -> some View {
        content
            .background(VaultWindowReader { window.value = $0 })
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { notification in
                guard notification.object as? NSWindow === window.value else { return }
                // A second SwiftUI sheet can claim the window before our sheet appears.
                // Keep the request queued so the next refresh can present it.
                if let active, presentedID != active.id {
                    self.active = nil
                } else {
                    presentPending()
                }
            }
            .onChange(of: anotherSheet) { _, _ in presentPending() }
            .sheet(item: $active, onDismiss: {
                presentedID = nil
                presentPending()
            }) { prompt in
                HerdrVaultRequestSheet(server: prompt.server, request: prompt.request) {
                    resolved[prompt.server.id, default: []].insert(prompt.id)
                    pending[prompt.server.id]?.removeAll { $0.id == prompt.id }
                    if active?.id == prompt.id { active = nil }
                }
                .onAppear { presentedID = prompt.id }
            }
    }

    private func presentPending() {
        guard !anotherSheet, active == nil, let window = window.value, window.isMainWindow,
              window.attachedSheet == nil else { return }
        active = store.herdrServers.compactMap { server in
            pending[server.id]?.first { $0.server == server }
        }.first
    }

    private func refresh() async {
        guard !store.isSetupPreview, store.herdrConfigured else { return }
        guard window.value?.isMainWindow == true || active != nil else {
            pending = [:]
            return
        }
        let servers = store.herdrServers
        await withTaskGroup(of: (HerdrServer, [HerdrVault.Request])?.self) { group in
            for server in servers {
                guard let client = try? store.herdrClient(for: server) else { continue }
                group.addTask {
                    guard let requests = try? await client.vaultRequests() else { return nil }
                    return (server, requests)
                }
            }
            for await result in group {
                guard let (server, requests) = result, !Task.isCancelled,
                      store.herdrServer(id: server.id) == server else { continue }
                let prompts = requests.map { Prompt(server: server, request: $0) }
                let seen = Set(prompts.map(\.id))
                resolved[server.id]?.formIntersection(seen)
                pending[server.id] = prompts.filter { resolved[server.id]?.contains($0.id) != true }
                if let active, active.server.id == server.id, !prompts.contains(where: { $0.id == active.id }) {
                    self.active = nil
                }
            }
        }
        if let active, store.herdrServer(id: active.server.id) != active.server { self.active = nil }
        presentPending()
    }
}

@MainActor
private struct VaultWindowReader: NSViewRepresentable {
    let changed: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: Reader, context: Context) { view.changed = changed }

    final class Reader: NSView {
        var changed: (@MainActor (NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            changed?(window)
        }
    }
}

@MainActor
private struct HerdrVaultRequestSheet: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var focused: Bool
    @State private var value = ""
    @State private var saving = false
    @State private var allowRepeated = false
    @State private var error: String?
    let server: HerdrServer
    let request: HerdrVault.Request
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault request").font(.title2)
            Text(verbatim: "\(request.bot) requests access on \(server.name).")
            Text(verbatim: request.label).font(.headline)
            Text(verbatim: request.name).font(.system(.body, design: .monospaced))
            Text(verbatim: request.description).foregroundStyle(.secondary)
            if request.needsValue {
                SecureField("Secret value", text: $value)
                    .focused($focused)
                    .disabled(saving)
            }
            Toggle("Allow up to 10 commands in 30 minutes", isOn: $allowRepeated)
                .disabled(saving)
            if let error { Text(error).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { decide(.cancel) }.keyboardShortcut(.cancelAction)
                Button(request.needsValue ? "Save and allow" : allowRepeated ? "Allow repeated use" : "Allow once") {
                    let secret = request.needsValue ? value : nil
                    decide(allowRepeated ? .allowRepeated(secret) : .save(secret))
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

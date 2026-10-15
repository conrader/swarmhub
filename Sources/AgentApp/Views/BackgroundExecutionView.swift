import AppKit
import SwiftUI

/// P38 B: background app access. A scoped worker on an agent's server can ask for app actions while this Mac is closed;
/// the SwarmHub service holds them, and "Check inbox" turns each waiting action into an approval card in that agent's
/// chat (P37 cards, always asked). Needs the SwarmHub connection service and the SwarmHub sign-in.
struct BackgroundExecutionView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var apps: ConnectedAppsStore
    @ObservedObject var center: ReportsCenter
    var checksOnAppear = true
    @State private var selected: UUID?
    @State private var rows: [ComposioValue] = []
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        Section("Background app access") {
            Text("A scoped worker on your agent's server can ask for app actions while this Mac is closed. They wait for your approval in the agent's chat.").font(.caption).foregroundStyle(.secondary)
            if store.connectedAppsServiceURL == nil {
                Text("Background app access needs the SwarmHub connection service, which this build does not include.").font(.caption).foregroundStyle(.secondary)
            } else if let serviceNote = apps.serviceNote {
                Label(serviceNote, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            } else if !signedIn {
                LabeledContent("Sign in to SwarmHub to use background app access.") { SettingsPaneButton(title: "Open Account", pane: .account) }
            } else {
                Picker("Agent", selection: $selected) {
                    Text("Choose an agent").tag(Optional<UUID>.none)
                    ForEach(store.bots.filter { store.connectionBot(id: $0.id) != nil }) { Text($0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("Export worker configuration…") { Task { await configure(revoke: false) } }.disabled(selected == nil || busy)
                    Button("Revoke worker", role: .destructive) { Task { await configure(revoke: true) } }.disabled(selected == nil || busy)
                    Spacer()
                    Button("Check inbox") { Task { await refresh() } }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row["tool"].string ?? "App action").font(.callout)
                            Text("\(botName(row)) · \(row["account"].string ?? "account")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row["state"].string == "awaitingApproval" ? "Waiting in the agent's chat" : (row["state"].string ?? "unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var signedIn: Bool { if case .signedIn = center.account { true } else { false } }
    private func botName(_ row: ComposioValue) -> String { store.bots.first { $0.id.uuidString.lowercased() == row["bot_id"].string?.lowercased() }?.name ?? "Unknown agent" }

    /// Registers the agent's worker with the accounts it may use (or revokes it) and saves the worker's configuration.
    private func configure(revoke: Bool) async {
        guard let selected, let client = store.backgroundExecutionClient() else { return }
        var destination: URL?
        if !revoke {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "swarmhub-worker.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        busy = true; defer { busy = false }
        do {
            var grants: [String: ComposioValue] = [:]
            if !revoke {
                for id in apps.grants(for: selected) {
                    guard let account = apps.accounts.first(where: { $0.id == id && $0.isActive }) else { continue }
                    grants[id] = .string(account.toolkit)
                }
            }
            let value = try await client.request("bots/" + selected.uuidString.lowercased(), body: .object(["accounts": .object(grants)]))
            if let destination, let token = value["token"].string {
                let config = ComposioValue.object(["service": .string(client.baseURL.absoluteString), "token": .string(token), "bot_id": .string(selected.uuidString.lowercased())])
                try JSONEncoder().encode(config).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                note = "Saved. Copy it to the agent's server for its worker."
            } else { note = revoke ? "The worker can no longer ask for app actions." : nil }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        busy = true; defer { busy = false }
        do {
            rows = try await store.refreshBackgroundInbox(); error = nil
            note = rows.isEmpty ? "Nothing in the inbox." : nil
        } catch { self.error = error.localizedDescription }
    }
}

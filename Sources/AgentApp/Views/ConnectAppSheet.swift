import SwiftUI

/// P38 B: the same first-connect provisioning and OAuth flow as Settings → Connected apps, with an explicit bot grant.
/// The Composio link opens in the browser (`ExternalLink`); P40: the first one gets the project key silently, no sign-in.
struct ConnectAppSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let request: AppConnectionRequest
    let botID: UUID
    @ObservedObject var apps: ConnectedAppsStore
    @State private var selectedAccountID: String?
    @State private var operation: Task<Void, Never>?

    private var bot: Bot? { store.connectionBot(id: botID) }
    private var name: String { apps.catalog.first { $0.id == request.toolkit }?.name ?? ComposioToolkit.popular.first { $0.id == request.toolkit }?.name ?? request.toolkit }
    private var accounts: [ComposioAccount] { apps.accounts.filter { $0.toolkit == request.toolkit && $0.isActive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Connect \(name)").font(.title2.weight(.semibold)); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let bot { Text("Choose the account \(bot.name) can use. App actions will still ask for your approval.").foregroundStyle(.secondary) }
            else { Text("This bot is no longer available.").foregroundStyle(.secondary) }
            if !request.reason.isEmpty { Text(request.reason).font(.callout) }
            if let note = apps.serviceNote, !apps.hasKey { Text(note).font(.callout).foregroundStyle(.secondary) }
            if let error = apps.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if apps.busy { HStack { ProgressView().controlSize(.small); Text("Preparing your connection…").font(.callout).foregroundStyle(.secondary) } }
            if !accounts.isEmpty {
                Picker("Account", selection: $selectedAccountID) {
                    Text("Choose an account").tag(Optional<String>.none)
                    ForEach(accounts) { account in Text(account.label).tag(Optional(account.id)) }
                }.disabled(apps.busy)
                if let bot {
                    Button("Allow \(bot.name)") { allow() }.buttonStyle(NeutralPrimaryButtonStyle())
                        .disabled(selectedAccountID == nil || apps.busy || !apps.canConfigure)
                }
                Divider()
            }
            HStack {
                Button(accounts.isEmpty ? "Connect \(name)" : "Connect another account") { connect() }
                    .buttonStyle(.bordered).disabled(apps.busy || bot == nil || !apps.canConfigure || (!apps.hasKey && apps.serviceNote != nil))
                if apps.hasKey { Button("Refresh") { refresh() }.disabled(apps.busy) }
            }
            if apps.pendingLink != nil { Text("Allow access in your browser, then return here and choose the account.").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 440)
            .task { if apps.hasKey { await apps.refresh() } else { await store.checkConnectedAppsService() }; chooseAccount() }
            .onChange(of: apps.accounts) { _, _ in chooseAccount() }
            .onChange(of: scenePhase) { _, phase in if phase == .active, apps.pendingLink != nil { refresh() } }
            .onDisappear { operation?.cancel() }
    }

    private func chooseAccount() {
        if accounts.contains(where: { $0.id == selectedAccountID }) { return }
        selectedAccountID = accounts.first(where: { apps.grants(for: botID).contains($0.id) })?.id ?? accounts.first?.id
    }
    private func connect() {
        operation?.cancel()
        operation = Task {
            if let url = await apps.connect(request.toolkit), !Task.isCancelled { ExternalLink.open(url) }
        }
    }
    private func refresh() {
        guard !apps.busy else { return }
        operation?.cancel()
        operation = Task { await apps.refresh(); chooseAccount() }
    }
    private func allow() {
        guard bot != nil, let selectedAccountID,
              apps.allowConnection(toolkit: request.toolkit, accountID: selectedAccountID, botID: botID) else { return }
        dismiss()
    }
}

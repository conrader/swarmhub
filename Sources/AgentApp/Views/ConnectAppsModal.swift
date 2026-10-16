import SwiftUI

/// P48: the bottom-left Connect apps sheet: what Composio is, a grid of apps with logos (popular first, then the full
/// catalog by search), each with its connected accounts by name and Connect / Add another account. A connect here is on
/// for every bot (P47) and is named after who it is (P48 item 3). Which bot uses which account stays in Settings.
struct ConnectAppsModal: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var apps: ConnectedAppsStore
    /// Renders pass false: no service check and no Composio request.
    var checksOnAppear = true
    @State var search = ""
    @State var searched = ""
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 24).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchBar
                    if let error = apps.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if let note = apps.serviceNote, !apps.hasKey { Label(note, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                    else if !apps.isAvailable { Text(ConnectedAppsCopy.serviceNotConfigured).font(.callout).foregroundStyle(.secondary) }
                    if apps.pendingLink != nil {
                        HStack {
                            Text("Allow access in your browser, then come back here.").font(.callout).foregroundStyle(.secondary)
                            Button("Refresh") { Task { await apps.refresh() } }.disabled(apps.busy)
                        }
                    }
                    if !searched.isEmpty { Text(shown.isEmpty ? "No apps match “\(searched)”." : "Results for “\(searched)”").font(.callout.weight(.medium)) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(shown) { app in ConnectAppTile(app: app, apps: apps, connect: { connect(app.id) }) }
                    }
                    if apps.nextCursor != nil, apps.hasKey { Button("Load more") { find(more: true) }.disabled(searching || apps.busy) }
                    if !apps.hasKey { Text("Connect your first app to search the full catalog.").font(.caption).foregroundStyle(.secondary) }
                }.padding(24)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 720, height: 680).background(AppColor.panel)
        .task {
            guard checksOnAppear else { return }
            if apps.hasKey { await apps.refresh(); if apps.catalog.count <= ComposioToolkit.popular.count { await apps.search("") } }
            else { await store.checkConnectedAppsService() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active, apps.pendingLink != nil { Task { await apps.refresh() } } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(ConnectedAppsCopy.connectAppsLabel).font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(ConnectedAppsCopy.composioExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Learn more about Composio") { ExternalLink.open(ConnectedAppsCopy.composioSite) }.buttonStyle(.link).font(.callout)
        }
    }

    private var searchBar: some View {
        HStack {
            TextField("Search apps", text: $search).textFieldStyle(.roundedBorder).onSubmit { find() }
            Button("Search") { find() }.disabled(searching || apps.busy)
            if searching || apps.busy { ProgressView().controlSize(.small) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Manage which bot uses which account in \(SettingsLayout.path(.apps)).").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") { store.settingsPane = .apps; openSettings(); dismiss() }
        }
    }

    /// Before a search: the popular apps first, then the rest of the catalog. After one: its results.
    private var shown: [ComposioToolkit] {
        guard searched.isEmpty else { return apps.catalog }
        let popular = ComposioToolkit.popular.map { app in apps.catalog.first { $0.id == app.id }.map { $0.logo == nil ? app : $0 } ?? app }
        return popular + apps.catalog.filter { app in !popular.contains { $0.id == app.id } }
    }

    private func find(more: Bool = false) {
        searching = true
        Task { await apps.search(search, more: more); searched = search.trimmingCharacters(in: .whitespacesAndNewlines); searching = false }
    }
    private func connect(_ slug: String) {
        Task { if let url = await apps.connect(slug, grantingTo: store.connectedAppsBots.map(\.id)) { ExternalLink.open(url) } }
    }
}

/// P48: one app in the Connect apps grid (and the chat connect sheet's header): logo, name, short detail, its connected
/// accounts by name, and Connect or Add another account.
struct ConnectAppTile: View {
    let app: ComposioToolkit
    @ObservedObject var apps: ConnectedAppsStore
    var connect: (() -> Void)?

    private var accounts: [ComposioAccount] { apps.accounts.filter { $0.toolkit == app.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppLogoView(app, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.callout.weight(.semibold)).lineLimit(1)
                    if !app.detail.isEmpty { Text(app.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            ForEach(accounts) { account in
                HStack(spacing: 5) {
                    Image(systemName: account.isActive ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(account.isActive ? .green : .orange).font(.caption)
                    Text(apps.namingAccounts.contains(account.id) ? "Getting the account name…" : account.label).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            if let connect {
                Spacer(minLength: 0)
                Button(accounts.isEmpty ? "Connect" : "Add another account", action: connect)
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(apps.busy || !apps.canConfigure || !apps.isAvailable || (!apps.hasKey && apps.serviceNote != nil))
            }
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
    }
}

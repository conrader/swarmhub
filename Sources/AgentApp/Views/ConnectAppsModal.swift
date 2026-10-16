import SwiftUI

/// P48: the bottom-left Connect apps sheet: what Composio is, a grid of apps with logos (popular first, then the full
/// catalog by search), each with its connected accounts by name and Connect / Add another account. A connect here is on
/// for every bot (P47) and is named after who it is (P48 item 3). Each account shows the bots it is on for, with a switch per bot.
/// The search field at the top filters the tiles at once and, after a pause, adds the full catalog's matches below.
struct ConnectAppsModal: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var apps: ConnectedAppsStore
    /// Renders pass false: no service check and no Composio request.
    var checksOnAppear = true
    @StateObject private var search: ConnectAppsSearch
    @FocusState private var searchFocused: Bool

    init(apps: ConnectedAppsStore, checksOnAppear: Bool = true, search: ConnectAppsSearch? = nil) {
        self.apps = apps; self.checksOnAppear = checksOnAppear
        _search = StateObject(wrappedValue: search ?? ConnectAppsSearch(apps: apps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 24).padding(.bottom, 14)
            Divider()
            searchBar.padding([.horizontal, .top], 24).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = apps.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    if let note = apps.serviceNote, !apps.hasKey { Label(note, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                    else if !apps.isAvailable { Text(ConnectedAppsCopy.serviceNotConfigured).font(.callout).foregroundStyle(.secondary) }
                    if apps.pendingLink != nil {
                        HStack {
                            Text("Allow access in your browser, then come back here.").font(.callout).foregroundStyle(.secondary)
                            Button("Refresh") { Task { await apps.refresh() } }.disabled(apps.busy)
                        }
                    }
                    let local = search.local(tiles), more = search.more(than: local)
                    grid(local)
                    if search.loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching all apps…").font(.callout).foregroundStyle(.secondary) }
                    }
                    if !more.isEmpty { Text("More apps").font(.callout.weight(.medium)).padding(.top, 4); grid(more) }
                    if search.nothingMatches(local: local) { Text("No apps match “\(search.term)”.").font(.callout).foregroundStyle(.secondary) }
                    if search.term.isEmpty, apps.nextCursor != nil, apps.hasKey { Button("Load more") { Task { await apps.search("", more: true) } }.disabled(apps.busy) }
                    if !apps.hasKey { Text("Connect your first app to search the full catalog.").font(.caption).foregroundStyle(.secondary) }
                }.padding(24)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 720, height: 680).background(AppColor.panel)
        .onAppear { searchFocused = true }
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
                // Escape clears a search first (`searchBar`); with none it closes the sheet.
                Button("Done") { dismiss() }.keyboardShortcut(search.text.isEmpty ? .cancelAction : nil)
            }
            Text(ConnectedAppsCopy.composioExplanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label(ConnectedAppsCopy.approvalRule, systemImage: "hand.raised").font(.callout)
            Button("Learn more about Composio") { ExternalLink.open(ConnectedAppsCopy.composioSite) }.buttonStyle(.link).font(.callout)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $search.text).textFieldStyle(.roundedBorder).focused($searchFocused)
                .onExitCommand { search.clear() }
            if apps.busy { ProgressView().controlSize(.small) }
        }
    }

    private func grid(_ apps: [ComposioToolkit]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], alignment: .leading, spacing: 12) {
            ForEach(apps) { app in ConnectAppTile(app: app, apps: self.apps, connect: { connect(app.id) }, bots: store.connectedAppsBots) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Manage which bot uses which account in \(SettingsLayout.path(.apps)).").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") { store.settingsPane = .apps; openSettings(); dismiss() }
        }
    }

    /// The popular apps first, then connected apps outside them, then the rest of the loaded catalog.
    private var tiles: [ComposioToolkit] { Self.tiles(apps) }
    static func tiles(_ apps: ConnectedAppsStore) -> [ComposioToolkit] {
        let popular = ComposioToolkit.popular.map { app in apps.catalog.first { $0.id == app.id }.map { $0.logo == nil ? app : $0 } ?? app }
        let connected = Set(apps.accounts.map(\.toolkit)).subtracting(popular.map(\.id)).sorted().compactMap { slug in
            apps.catalog.first { $0.id == slug } ?? ComposioToolkit(.object(["slug": .string(slug), "name": .string(apps.appName(slug))]))
        }
        let shown = popular + connected
        return shown + apps.catalog.filter { app in !shown.contains { $0.id == app.id } }
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
    /// The Connect apps sheet passes the eligible bots: each account then shows which of them use it.
    var bots: [Bot]? = nil

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
                if let bots { AccountUsageLine(account: account, bots: bots, apps: apps).padding(.leading, 17) }
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

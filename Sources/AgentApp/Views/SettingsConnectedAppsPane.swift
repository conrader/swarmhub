import SwiftUI

/// P38 B: Settings → Advanced → Connected apps: ChatGPT, Composio apps, which bot may use which account, and background
/// app access. P40: the first Connect gets this Mac's project key from SwarmHub silently (no sign-in); the user's own
/// Composio key sits under Advanced. A service that is not set up says so in one plain line instead of dead controls.
struct SettingsConnectedAppsPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var apps: ConnectedAppsStore
    @ObservedObject var chatGPT: ChatGPTConnection
    /// Renders pass false: no Codex process, no service check, no Composio request.
    var checksOnAppear = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var key = ""
    @State private var search = ""
    @State private var selectedBotID: UUID?
    @State private var disconnecting: ComposioAccount?
    @State private var searching = false

    var body: some View {
        ChatGPTConnectedAppSection(account: chatGPT, checksOnAppear: checksOnAppear)
        Section("Apps") {
            Text("Connect your apps once, then choose which agents can use each account. Every app action asks you first.").font(.callout).foregroundStyle(.secondary)
            if !apps.hasKey { serviceLine }
            if apps.busy && !apps.hasKey {
                HStack { ProgressView().controlSize(.small); Text("Preparing your app connection…").font(.caption).foregroundStyle(.secondary) }
            }
            DisclosureGroup("Advanced") {
                Text("Use your own Composio key").font(.callout)
                SecureField(apps.hasKey ? "Replace project API key" : "Project API key", text: $key)
                HStack {
                    Button("Save key") { if apps.saveKey(key) { key = ""; Task { await load() } } }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apps.busy || !apps.canConfigure)
                    Button("Get a Composio key") { ExternalLink.open(URL(string: "https://platform.composio.dev/")!) }.buttonStyle(.link)
                }
                if apps.hasKey { Button("Remove key", role: .destructive) { _ = apps.saveKey(""); key = "" }.disabled(apps.busy) }
            }
        }
        if let error = apps.error {
            Section {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if let toolkit = apps.retryToolkit { Button("Retry") { connect(toolkit) }.disabled(apps.busy) }
            }
        }
        if apps.hasKey {
            Section("Connected accounts") {
                HStack {
                    Button("Refresh") { Task { await apps.refresh() } }.disabled(apps.busy)
                    if apps.busy { ProgressView().controlSize(.small) }
                    if apps.pendingLink != nil { Text("Allow access in your browser, then refresh.").font(.caption).foregroundStyle(.secondary) }
                }
                if apps.accounts.isEmpty { Text("No accounts connected yet. Choose an app below.").foregroundStyle(.secondary) }
                ForEach(apps.accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.label)
                            Text("\(appName(account.toolkit)) · \(status(account))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !account.isActive { Button("Reconnect") { connect(account.toolkit) }.disabled(apps.busy) }
                        Button("Disconnect", role: .destructive) { disconnecting = account }.disabled(apps.busy)
                    }
                }
            }
            Section("Agent access") {
                if availableBots.isEmpty { Text("Add a Hermes agent to choose its app access.").foregroundStyle(.secondary) }
                else {
                    Picker("Agent", selection: $selectedBotID) {
                        Text("Choose an agent").tag(Optional<UUID>.none)
                        ForEach(availableBots) { bot in Text(bot.name).tag(Optional(bot.id)) }
                    }
                    if let selectedBotID {
                        ForEach(apps.accounts) { account in
                            Toggle("\(appName(account.toolkit)) · \(account.label)", isOn: Binding(
                                get: { apps.allows(account, botID: selectedBotID) },
                                set: { apps.setAllowed($0, account: account, botID: selectedBotID) }
                            )).disabled(apps.busy || !account.isActive && !apps.allows(account, botID: selectedBotID))
                        }
                    }
                }
                Text("One account per app for each agent. App actions appear for your approval in that agent's chat.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if apps.isAvailable {
            Section(apps.hasKey ? "Find apps" : "Popular apps") {
                HStack {
                    TextField("Search apps", text: $search).onSubmit { find() }
                    Button("Search") { find() }.disabled(searching || apps.busy)
                    if searching { ProgressView().controlSize(.small) }
                }
                ForEach(apps.catalog) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                            if !app.detail.isEmpty { Text(app.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Button("Connect") { connect(app.id) }.disabled(apps.busy || !apps.canConfigure || (!apps.hasKey && apps.serviceNote != nil))
                    }
                }
                if apps.nextCursor != nil { Button("Load more") { find(more: true) }.disabled(searching || apps.busy) }
                if !apps.hasKey { Text("Connect your first app to browse the full catalog.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        BackgroundExecutionView()
        Section {
            Text("App connections belong to SwarmHub. Connected accounts remain in Composio when you remove the key.").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            if selectedBotID == nil { selectedBotID = availableBots.first?.id }
            if checksOnAppear { await store.checkConnectedAppsService(); await load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, apps.pendingLink != nil { Task { await apps.refresh() } }
        }
        .confirmationDialog("Disconnect this account from SwarmHub?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            if let account = disconnecting {
                Button("Disconnect \(account.label)", role: .destructive) { disconnecting = nil; Task { await apps.disconnect(account) } }
            }
        } message: { Text("All agents lose access to this connection. To revoke the provider's OAuth consent, use that app's account settings.") }
    }

    /// The first connection's route: the server not set up, this build without the service, or ready.
    @ViewBuilder private var serviceLine: some View {
        if let note = apps.serviceNote {
            Label(note, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
        } else if apps.provisioner == nil {
            Text(ConnectedAppsCopy.serviceNotConfigured).font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Choose an app below. Its own page opens in your browser to allow access.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var availableBots: [Bot] { store.bots.filter { store.connectionBot(id: $0.id) != nil } }
    private func appName(_ slug: String) -> String { apps.catalog.first { $0.id == slug }?.name ?? slug.replacingOccurrences(of: "_", with: " ").capitalized }
    private func status(_ account: ComposioAccount) -> String { account.isActive ? "Connected" : account.disabled ? "Disabled" : account.status.replacingOccurrences(of: "_", with: " ").capitalized }
    private func load() async { if apps.hasKey { await apps.refresh() }; if apps.catalog.isEmpty || !apps.hasKey { await apps.search("") } }
    private func find(more: Bool = false) { searching = true; Task { await apps.search(search, more: more); searching = false } }
    private func connect(_ slug: String) { Task { if let url = await apps.connect(slug) { ExternalLink.open(url); await apps.search(search) } } }
}

/// P38 B: a Hermes agent's connected app accounts in its Overview tab; only shown where app connections are possible.
struct BotConnectedAppsSection: View {
    @ObservedObject var apps: ConnectedAppsStore
    @ObservedObject var bot: Bot
    var body: some View {
        if apps.isAvailable {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Connected apps").font(.headline); Spacer(); Text("\(apps.grants(for: bot.id).count) enabled").font(.caption).foregroundStyle(.secondary) }
                if apps.accounts.isEmpty {
                    Text("Connect apps in \(SettingsLayout.path(.apps)).").font(.caption).foregroundStyle(.secondary)
                    if apps.hasKey { Button("Load accounts") { Task { await apps.refresh() } }.disabled(apps.busy) }
                }
                ForEach(apps.accounts) { account in
                    Toggle(account.label, isOn: Binding(get: { apps.allows(account, botID: bot.id) }, set: { apps.setAllowed($0, account: account, botID: bot.id) }))
                        .font(.system(size: 12)).disabled(apps.busy || !account.isActive && !apps.allows(account, botID: bot.id))
                }
                if !bot.requestedConnectorIDs.isEmpty {
                    Text("Suggested by this agent: " + bot.requestedConnectorIDs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Text("App actions ask for your approval in chat.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

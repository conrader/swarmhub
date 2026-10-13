import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    private enum Pane: String, CaseIterable, Identifiable { case account = "Account", appearance = "Appearance", notifications = "Notifications", computers = "Computers", review = "Auto-review", usage = "Usage", updates = "Updates"; var id: String { rawValue }; var icon: String { switch self { case .account: "person.crop.circle"; case .appearance: "paintpalette"; case .notifications: "bell"; case .computers: "desktopcomputer"; case .review: "checkmark.shield"; case .usage: "chart.bar"; case .updates: "arrow.triangle.2.circlepath" } } }
    @State private var pane = Pane.account
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference; @AppStorage("accent") private var accent = "Graphite"; @AppStorage("notifications") private var notifications = false
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL; @AppStorage("openClawURL") private var openClawURL = "ws://127.0.0.1:18789"
    @AppStorage("hermesProfiles") private var hermesProfiles = ""
    @AppStorage("noVNCURL") private var noVNCURL = ""
    @State private var apiKey = ""; @State private var testResult = ""; @State private var testing = false
    @State private var boxPaste = ""; @State private var addResults: [HermesBotAddResult] = []; @State private var adding = false
    var body: some View {
        NavigationSplitView { List(Pane.allCases, selection: $pane) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }.navigationSplitViewColumnWidth(170) } detail: { Form { content }.formStyle(.grouped).navigationTitle(pane.rawValue) }
            .frame(width: 720, height: 500).background(AppColor.panel).onAppear { apiKey = KeychainStore.get(account: "hermes") }
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .account:
            LabeledContent("Name", value: "Konrad"); LabeledContent("Workspace", value: "Personal"); Button("Manage account…") { }.disabled(true); Text("TODO: account management requires a workspace identity provider.").font(.caption).foregroundStyle(.secondary)
        case .appearance:
            Picker("Theme", selection: $appearance) { Text("Dark").tag("Dark"); Text("Light").tag("Light"); Text("System").tag("System") }.pickerStyle(.segmented)
            Picker("Accent", selection: $accent) { ForEach(["Graphite", "Blue", "Purple", "Orange"], id: \.self) { Text($0) } }
        case .notifications:
            Toggle("New messages", isOn: $notifications).onChange(of: notifications) { _, enabled in
                guard enabled, Bundle.main.bundleIdentifier != nil else { return }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            if Bundle.main.bundleIdentifier == nil { Text("Notifications require running " + AppConstants.name + " from an application bundle.").font(.caption).foregroundStyle(.secondary) }
            Text("Each bot can be muted from its context menu or settings.").font(.caption).foregroundStyle(.secondary)
        case .computers:
            Section("Hermes Agent") {
                TextField("Base URL", text: $hermesURL)
                SecureField("Default profile API key", text: $apiKey).onChange(of: apiKey) { _, value in KeychainStore.set(value, account: "hermes") }
                TextField("Named profiles (comma-separated)", text: $hermesProfiles)
                Text("Hermes does not expose profile enumeration on its API-key server. Add named multiplex profiles here; each requires its own key.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Test & Discover") { testHermes() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(testResult).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Add bots from box") {
                TextEditor(text: $boxPaste).font(.system(.callout, design: .monospaced)).frame(minHeight: 64)
                Text("One profile=key per line (commas also work). Keys are saved to the Keychain, each profile is checked, and new bots are named from the profile slug.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Add bots") { addBots() }.disabled(adding || boxPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if adding { ProgressView().controlSize(.small) } }
                ForEach(addResults) { result in Text("\(result.label): \(result.summary)").font(.caption).foregroundStyle(.secondary) }
            }
            Section("OpenClaw") { TextField("Gateway URL", text: $openClawURL); Text("TODO: authenticated WebSocket RPC transport.").font(.caption).foregroundStyle(.secondary) }
            Section("Virtual desktop") { TextField("noVNC URL", text: $noVNCURL) }
        case .review:
            Text("Approval policy is configured per bot.")
            Text("Open a bot’s settings to choose Ask me, ordered allow/deny/ask rules, or another bot as reviewer. Approval history is visible in that bot’s Overview panel.").font(.caption).foregroundStyle(.secondary)
        case .usage:
            LabeledContent("Messages this month", value: "128"); LabeledContent("Backend cost", value: "Provided by your agent"); Text("TODO: pull usage metering from Hermes/OpenClaw when their APIs expose it.").font(.caption).foregroundStyle(.secondary)
        case .updates:
            LabeledContent("Version", value: "Prototype"); Text("You’re up to date").foregroundStyle(.secondary); Button("Check for Updates") { }
        }
    }
    private func addBots() {
        adding = true; let text = boxPaste; boxPaste = ""
        Task { addResults = await store.addBotsFromBox(text); adding = false }
    }
    private func testHermes() {
        testing = true; testResult = ""
        Task {
            do {
                guard let baseURL = HermesBackend.validatedBaseURL(hermesURL) else { throw BackendError.invalidURL }
                let backend = HermesBackend(baseURL: baseURL, apiKey: apiKey)
                let status = try await backend.testConnection()
                let probes = await store.refreshHermesAgents()
                let available = probes.filter { $0.status.reason == nil }.count
                let problems = probes.compactMap { probe in probe.status.reason.map { "\(probe.id): \($0)" } }
                testResult = (["\(status); \(available) profile(s) available"] + problems).joined(separator: "\n")
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

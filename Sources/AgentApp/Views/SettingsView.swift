import SwiftUI
import UserNotifications

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable { case account = "Account", appearance = "Appearance", notifications = "Notifications", computers = "Computers", review = "Auto-review", usage = "Usage", updates = "Updates"; var id: String { rawValue }; var icon: String { switch self { case .account: "person.crop.circle"; case .appearance: "paintpalette"; case .notifications: "bell"; case .computers: "desktopcomputer"; case .review: "checkmark.shield"; case .usage: "chart.bar"; case .updates: "arrow.triangle.2.circlepath" } } }
    @State private var pane = Pane.account
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference; @AppStorage("accent") private var accent = "Graphite"; @AppStorage("notifications") private var notifications = false
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL; @AppStorage("openClawURL") private var openClawURL = "ws://127.0.0.1:18789"
    @AppStorage("noVNCURL") private var noVNCURL = ""; @AppStorage("autoReview") private var autoReview = false
    @State private var apiKey = ""; @State private var testResult = ""; @State private var testing = false
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
            if Bundle.main.bundleIdentifier == nil { Text("Notifications require running AgentApp from an application bundle.").font(.caption).foregroundStyle(.secondary) }
            Text("Each bot can be muted from its context menu or settings.").font(.caption).foregroundStyle(.secondary)
        case .computers:
            Section("Hermes Agent") { TextField("Base URL", text: $hermesURL); SecureField("API key", text: $apiKey).onChange(of: apiKey) { _, value in KeychainStore.set(value, account: "hermes") }; HStack { Button("Test Connection") { testHermes() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(testResult).font(.caption).foregroundStyle(.secondary) } }
            Section("OpenClaw") { TextField("Gateway URL", text: $openClawURL); Text("TODO: authenticated WebSocket RPC transport.").font(.caption).foregroundStyle(.secondary) }
            Section("Virtual desktop") { TextField("noVNC URL", text: $noVNCURL) }
        case .review:
            Toggle("Review low-risk actions automatically", isOn: $autoReview); Text("High-impact actions still require explicit approval. TODO: backend policy synchronization.").font(.caption).foregroundStyle(.secondary)
        case .usage:
            LabeledContent("Messages this month", value: "128"); LabeledContent("Backend cost", value: "Provided by your agent"); Text("TODO: pull usage metering from Hermes/OpenClaw when their APIs expose it.").font(.caption).foregroundStyle(.secondary)
        case .updates:
            LabeledContent("Version", value: "Prototype"); Text("You’re up to date").foregroundStyle(.secondary); Button("Check for Updates") { }
        }
    }
    private func testHermes() {
        testing = true; testResult = ""
        Task {
            do {
                guard let baseURL = HermesBackend.validatedBaseURL(hermesURL) else { throw BackendError.invalidURL }
                testResult = try await HermesBackend(baseURL: baseURL, apiKey: apiKey).testConnection()
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

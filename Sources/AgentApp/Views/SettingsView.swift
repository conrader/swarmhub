import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "System"; @AppStorage("notifications") private var notifications = true
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL; @AppStorage("openClawURL") private var openClawURL = "ws://127.0.0.1:18789"
    @AppStorage("noVNCURL") private var noVNCURL = ""; @State private var apiKey = ""; @State private var testResult = ""; @State private var testing = false
    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Theme", selection: $appearance) { Text("Follow System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark") }.pickerStyle(.segmented)
                    Toggle("Notifications", isOn: $notifications)
                }
            }.formStyle(.grouped).padding(.horizontal, 10).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Hermes Agent") { TextField("Base URL", text: $hermesURL); SecureField("API key", text: $apiKey).onChange(of: apiKey) { _, value in KeychainStore.set(value, account: "hermes") }; HStack { Button("Test Connection") { testHermes() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(testResult).font(.caption).foregroundStyle(.secondary) } }
                Section("OpenClaw") { TextField("Gateway URL", text: $openClawURL) }
                Section("Virtual desktop") { TextField("noVNC URL", text: $noVNCURL) }
            }.formStyle(.grouped).padding(.horizontal, 10).tabItem { Label("Computer", systemImage: "desktopcomputer") }
            VStack(spacing: 12) { Text(AppConstants.name).font(.title2.bold()); Text("You’re up to date").foregroundStyle(.secondary); Button("Check for Updates") { } }.frame(maxWidth: .infinity, maxHeight: .infinity).tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }.frame(width: 560, height: 420).tint(.primary).preferredColorScheme(appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil).onAppear { apiKey = KeychainStore.get(account: "hermes") }
    }
    private func testHermes() { testing = true; testResult = ""; Task { do { testResult = try await HermesBackend(baseURL: URL(string: hermesURL) ?? URL(string: AppConstants.defaultHermesURL)!, apiKey: apiKey).testConnection() } catch { testResult = error.localizedDescription }; testing = false } }
}

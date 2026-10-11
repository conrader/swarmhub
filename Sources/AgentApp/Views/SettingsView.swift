import SwiftUI

struct SettingsView: View {
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL
    @AppStorage("openClawURL") private var openClawURL = "ws://127.0.0.1:18789"
    @AppStorage("noVNCURL") private var noVNCURL = ""
    @State private var apiKey = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        TabView {
            Form {
                Section("Hermes Agent") {
                    TextField("Base URL", text: $hermesURL)
                    SecureField("API key", text: $apiKey).onChange(of: apiKey) { _, value in KeychainStore.set(value, account: "hermes") }
                    HStack { Button("Test Connection") { testHermes() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
                Section("OpenClaw (stub)") { TextField("Gateway WebSocket URL", text: $openClawURL); Text("The protocol adapter is scaffolded; WebSocket authentication and RPC events are next.").font(.caption).foregroundStyle(.secondary) }
            }.padding().tabItem { Label("Backends", systemImage: "server.rack") }
            Form {
                Section("Virtual Desktop") { TextField("noVNC URL", text: $noVNCURL) }
                Section("Appearance") { LabeledContent("Theme", value: "Follow System") }
            }.padding().tabItem { Label("Appearance", systemImage: "paintbrush") }
        }.frame(width: 570, height: 360).onAppear { apiKey = KeychainStore.get(account: "hermes") }
    }
    private func testHermes() {
        testing = true; testResult = ""
        Task {
            do { testResult = try await HermesBackend(baseURL: URL(string: hermesURL) ?? URL(string: AppConstants.defaultHermesURL)!, apiKey: apiKey).testConnection() }
            catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

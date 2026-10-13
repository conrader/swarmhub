import SwiftUI

/// Settings → Account: the Hermes server, the profiles the bots are bound to (with a per-profile Test),
/// "Add bots from box" and the OpenClaw gateway.
struct SettingsAccountPane: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL; @AppStorage("openClawURL") private var openClawURL = "ws://127.0.0.1:18789"
    @AppStorage("hermesProfiles") private var hermesProfiles = ""
    @State private var apiKey = ""; @State private var testResult = ""; @State private var testing = false
    @State private var boxPaste = ""; @State private var addResults: [HermesBotAddResult] = []; @State private var adding = false
    @State private var profileResults: [String: String] = [:]; @State private var testingProfiles: Set<String> = []

    var body: some View {
        Section("Hermes server") {
            TextField("Base URL", text: $hermesURL)
            SecureField("Default profile API key", text: $apiKey).onChange(of: apiKey) { _, value in KeychainStore.set(value, account: "hermes") }
            TextField("Named profiles (comma-separated)", text: $hermesProfiles)
            Text("Hermes does not expose profile enumeration on its API-key server. Add named multiplex profiles here; each requires its own key.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Test & Discover") { testHermes() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(testResult).font(.caption).foregroundStyle(.secondary) }
        }
        Section("Connected profiles") {
            let profiles = store.usageProfiles
            if profiles.isEmpty { Text("No bot is bound to a Hermes profile yet.").foregroundStyle(.secondary) }
            ForEach(Array(profiles.enumerated()), id: \.offset) { _, entry in
                let id = "\(entry.server)|\(entry.profile)"
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.bots.map(\.name).joined(separator: ", ")).fontWeight(.medium)
                        Spacer()
                        if testingProfiles.contains(id) { ProgressView().controlSize(.small) }
                        Button("Test") { test(entry.bots[0], id: id) }.disabled(testingProfiles.contains(id))
                    }
                    Text("\(entry.profile) · \(URL(string: entry.server)?.host ?? entry.server) · key \(keyState(entry.profile))").font(.caption).foregroundStyle(.secondary)
                    if let result = profileResults[id] { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        Section("Add bots from box") {
            TextEditor(text: $boxPaste).font(.system(.callout, design: .monospaced)).frame(minHeight: 64)
            Text("One profile=key per line (commas also work). Keys are saved to the Keychain, each profile is checked, and new bots are named from the profile slug.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Add bots") { addBots() }.disabled(adding || boxPaste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if adding { ProgressView().controlSize(.small) } }
            ForEach(addResults) { result in Text("\(result.label): \(result.summary)").font(.caption).foregroundStyle(.secondary) }
        }
        Section("OpenClaw") { TextField("Gateway URL", text: $openClawURL); Text("The OpenClaw WebSocket RPC transport is not implemented yet.").font(.caption).foregroundStyle(.secondary) }
            .onAppear { apiKey = KeychainStore.get(account: "hermes") }
    }

    /// From item attributes only, so listing profiles never asks for Keychain access.
    private func keyState(_ profile: String) -> String { store.keyStore.hasKey(for: AppStore.keyAccount(forProfile: profile)) ? "saved" : "missing" }

    /// The same read-only probe as `--check-bots` (`/v1/models`, `/v1/capabilities`, `/api/jobs`).
    private func test(_ bot: Bot, id: String) {
        testingProfiles.insert(id); profileResults[id] = nil
        Task {
            let check = await HeadlessCommands.checkBot(bot, store: store)
            profileResults[id] = check.ok ? "OK — model \(check.modelID ?? "?")" + (check.routines.map { ", routines \($0)" } ?? "") : HeadlessCommands.line(check).components(separatedBy: " | ").dropFirst(2).joined(separator: " · ")
            testingProfiles.remove(id)
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

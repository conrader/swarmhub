import SwiftUI

/// Settings → Advanced → Servers and keys (Account before P21; "Your name" moved to the simple page): the connection's Hermes version, the Hermes server, the profiles the bots are bound to (with a
/// per-profile Test and version), "Add bots from box" (`BoxKeysPasteSection`), Grok Bot and the OpenClaw Gateways
/// (`OpenClawSettingsSection`, P12).
struct SettingsAccountPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var cache: BotInfoCache
    @AppStorage("hermesBaseURL") private var hermesURL = AppConstants.defaultHermesURL
    @AppStorage("hermesProfiles") private var hermesProfiles = ""
    @State private var apiKey = ""; @State private var testResult = ""; @State private var testing = false
    @State private var profileResults: [String: String] = [:]; @State private var testingProfiles: Set<String> = []

    var body: some View {
        Section("Connection") {
            let lines = store.connectionVersionLines
            if lines.isEmpty { Text("No bot is connected to a Hermes server yet.").foregroundStyle(.secondary) }
            ForEach(lines, id: \.server) { line in
                LabeledContent(line.server) { Text(line.reading?.label ?? "Reading the Hermes version…").foregroundStyle(.secondary) }
            }
            Text("Versions SwarmHub has run against are marked “works”; others are “not tested yet”.").font(.caption).foregroundStyle(.secondary)
            // P31 C: coding tools and account logins per connection.
            ForEach(store.hermesConnections, id: \.target) { connection in
                LabeledContent("Coding tools and accounts on \(connection.host)") { AccountsButton(target: AccountsTarget(id: connection.target, host: connection.host)) }
            }
        }
        .task { await store.loadHermesVersions() }
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
                    Text(versionText(entry.bots[0])).font(.caption).foregroundStyle(.secondary)
                    if store.keyNeedsReentry(entry.bots[0]) { ReenterKeyField(bot: entry.bots[0]) }
                    if let result = profileResults[id] { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        DeviceApprovalEnrollmentSection()
        AddAllBotsSection()
        // P42: the messaging skills on every bot, one confirmation.
        AllBotsSkillsSection()
        BoxKeysPasteSection()
        SettingsGrokSection()
        // P12: the Gateways' own section (it used to be a URL field here).
        OpenClawSettingsSection(status: store.openClawStatus)
            .onAppear { apiKey = KeychainStore.get(account: "hermes") }
    }

    private func versionText(_ bot: Bot) -> String {
        guard let reading = store.hermesVersion(for: bot) else { return "Hermes version not read yet" }
        return reading.label + (reading.raw == nil ? reading.problem.map { " (\($0))" } ?? "" : "")
    }

    /// From item attributes only, so listing profiles never asks for Keychain access.
    private func keyState(_ profile: String) -> String {
        let account = AppStore.keyAccount(forProfile: profile)
        if store.keyStore.needsReentry(account) { return "needs re-entry" }
        return store.keyStore.hasKey(for: account) ? "saved" : "missing"
    }

    /// The same read-only probe as `--check-bots` (`/v1/models`, `/v1/capabilities`, `/api/jobs`).
    private func test(_ bot: Bot, id: String) {
        testingProfiles.insert(id); profileResults[id] = nil
        Task {
            let check = await HeadlessCommands.checkBot(bot, store: store)
            profileResults[id] = check.ok ? "OK — model \(check.modelID ?? "?")" + (check.routines.map { ", routines \($0)" } ?? "") : HeadlessCommands.line(check).components(separatedBy: " | ").dropFirst(2).joined(separator: " · ")
            testingProfiles.remove(id)
        }
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
                await store.loadHermesVersions(force: true)
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

/// "Re-enter this bot's key" under a profile whose stored key could not be read without a dialog.
struct ReenterKeyField: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    @State private var key = ""

    var body: some View {
        HStack {
            Text(KeychainStore.reenterMessage).font(.caption).foregroundStyle(.orange)
            SecureField("API key", text: $key).onSubmit(save)
            Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() { store.saveKey(key, for: bot); key = "" }
}

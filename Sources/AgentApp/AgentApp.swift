import AppKit
import Darwin
import SwiftUI

@main struct AgentAppMain: App {
    @StateObject private var store: AppStore
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference
    private let snapshotAppearance: String?
    init() {
        snapshotAppearance = ProcessInfo.processInfo.environment["AGENTAPP_APPEARANCE"]
        let integration = ProcessInfo.processInfo.environment["AGENTAPP_HERMES_INTEGRATION"] == "1"
        let integrationStoreURL = integration ? FileManager.default.temporaryDirectory.appending(path: "AgentApp-Hermes-\(UUID().uuidString)/store.json") : nil
        let appStore = AppStore(demoMode: ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] != nil, storeURL: integrationStoreURL, autoConfigureHermes: !integration)
        _store = StateObject(wrappedValue: appStore)
        PerformanceMetrics.reportReady()
        if integration {
            Task { exit(await Self.runHermesIntegration(storeURL: integrationStoreURL!) ? 0 : 1) }
        }
        if ProcessInfo.processInfo.environment["AGENTAPP_BENCHMARK"] == "1" { exit(0) }
        if let path = ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] { SnapshotRenderer.capture(store: appStore, to: path); exit(0) }
    }
    private static func runHermesIntegration(storeURL: URL) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let url = HermesBackend.validatedBaseURL(env["HERMES_TEST_URL"] ?? AppConstants.defaultHermesURL) else { print("Hermes integration: invalid URL"); return false }
        let backend = HermesBackend(baseURL: url, apiKey: env["HERMES_TEST_KEY"] ?? "")
        do {
            print("Hermes integration: \(try await backend.testConnection())")
            let profiles = try await backend.discoverProfiles(); print("Hermes integration: profiles=\(profiles.map(\.id))")
            guard storeURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { throw BackendError.unavailable("Integration store is not temporary.") }
            let mode = try await backend.transport()
            let listedSessions: [BackendSession]; let id: String
            if mode == .nativeSessions {
                listedSessions = try await backend.listSessions()
                let ownedID = "agentapp_integration_\(UUID().uuidString.lowercased())"
                id = try await backend.createSession(title: "AgentApp integration \(ownedID.suffix(8))", systemPrompt: "Integration test", id: ownedID)
                _ = try await backend.loadMessages(sessionID: id)
            } else {
                listedSessions = []; id = "agentapp_legacy_integration"
            }
            let stream = try await backend.send(.init(sessionID: id, systemPrompt: "Integration test", messages: [(role: "user", content: "Reply with echo")]))
            var kinds: [String] = []
            var reply = ""; var approvalResolved = false; var stopRequested = false
            for try await event in stream { switch event {
            case .token(let token): kinds.append("token"); reply += token
            case .status: kinds.append("status")
            case .subAgent: kinds.append("subagent")
            case .approval(let request):
                kinds.append("approval"); try await backend.resolveApproval(request, approved: false); approvalResolved = true
                if env["HERMES_TEST_CANCEL"] == "1" { stopRequested = try await backend.cancel(sessionID: id) == .requested }
            case .completed: kinds.append("completed")
            case .failed(let message): throw BackendError.unavailable(message)
            } }
            if env["HERMES_TEST_FIXTURE"] == "native" {
                guard reply == "fixture reply" else { throw BackendError.unavailable("Expected one fixture reply, got \(String(reflecting: reply)).") }
                guard approvalResolved else { throw BackendError.unavailable("No approval event was resolved.") }
                if env["HERMES_TEST_CANCEL"] == "1", !stopRequested { throw BackendError.unavailable("Stop was not accepted by Hermes.") }
            } else if env["HERMES_TEST_FIXTURE"] == "legacy" {
                guard mode == .legacyChatCompletions, reply == "legacy fixture reply" else { throw BackendError.unavailable("Legacy fallback was not used correctly.") }
            } else if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BackendError.unavailable("The live Hermes stream returned no assistant result.")
            } else if reply.contains("Provider authentication failed") {
                throw BackendError.unavailable("The live Hermes gateway routed the turn, but its throwaway provider credentials were unavailable.")
            }
            print("Hermes integration: listed=\(listedSessions.count) created=\(id) events=\(kinds)")
            return true
        } catch { print("Hermes integration failed: \(error.localizedDescription)"); return false }
    }
    var body: some Scene {
        WindowGroup(AppConstants.name) {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(AppTheme.colorScheme(for: snapshotAppearance ?? appearance))
                .frame(minWidth: 980, minHeight: 620)
        }
            .defaultSize(width: 1120, height: 760)
            .commands {
                CommandGroup(after: .newItem) { Button("New Agent") { NotificationCenter.default.post(name: .newBot, object: nil) }.keyboardShortcut("n") }
                CommandMenu("Navigate") {
                    Button("Quick Switcher") { NotificationCenter.default.post(name: .commandPalette, object: nil) }.keyboardShortcut("k")
                    Button("Toggle Agent Info") { NotificationCenter.default.post(name: .toggleInfo, object: nil) }.keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
        Settings {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
        }
    }
}

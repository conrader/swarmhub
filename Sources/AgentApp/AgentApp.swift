import AppKit
import Darwin
import SwiftUI

private struct FixtureReviewerBackend: AgentBackend {
    let kind = BackendKind.mock
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> { AsyncThrowingStream { continuation in continuation.yield(.token("escalate")); continuation.yield(.completed); continuation.finish() } }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "fixture reviewer" }
}

@main struct AgentAppMain: App {
    @StateObject private var store: AppStore
    @StateObject private var updater: AppUpdater
    @NSApplicationDelegateAdaptor(AppIconAppearance.self) private var iconAppearance
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    private let snapshotAppearance: String?
    init() {
        if let code = HeadlessCommands.runIfRequested() { exit(code) }
        SidebarWidth.dropStaleSavedWidths()
        snapshotAppearance = ProcessInfo.processInfo.environment["AGENTAPP_APPEARANCE"]
        let integration = ProcessInfo.processInfo.environment["AGENTAPP_HERMES_INTEGRATION"] == "1"
        let integrationStoreURL = integration ? FileManager.default.temporaryDirectory.appending(path: "AgentApp-Hermes-\(UUID().uuidString)/store.json") : nil
        let appStore = SetupPreview.isRequested() ? SetupPreview.makeStore()
            : AppStore(demoMode: ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] != nil, storeURL: integrationStoreURL, autoConfigureHermes: !integration)
        _store = StateObject(wrappedValue: appStore)
        if let path = UISmoke.reportPath() { UISmoke.start(store: appStore, path: path) }
        PerformanceMetrics.reportReady()
        if integration {
            Task { exit(await Self.runHermesIntegration(storeURL: integrationStoreURL!) ? 0 : 1) }
        }
        if ProcessInfo.processInfo.environment["AGENTAPP_BENCHMARK"] == "1" { exit(0) }
        if let path = ProcessInfo.processInfo.environment["AGENTAPP_SNAPSHOT"] { SnapshotRenderer.capture(store: appStore, to: path); exit(0) }
        _updater = StateObject(wrappedValue: AppUpdater())
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
                id = try await backend.createSession(title: "\(AppConstants.name) integration \(ownedID.suffix(8))", systemPrompt: "Integration test", id: ownedID)
                _ = try await backend.loadMessages(sessionID: id)
            } else {
                listedSessions = []; id = "agentapp_legacy_integration"
            }
            let stream = try await backend.send(.init(sessionID: id, systemPrompt: "Integration test", messages: [(role: "user", content: "Reply with echo")]))
            var kinds: [String] = []
            var reply = ""; var approvalResolved = false; var stopRequested = false; var approvalCount = 0
            let policyStore = AppStore(storeURL: storeURL.deletingLastPathComponent().appending(path: "policy-store.json"), autoConfigureHermes: false, backendFactory: { candidate -> any AgentBackend in
                if candidate.name == "Fixture reviewer" { return FixtureReviewerBackend() }
                return backend
            })
            let policyBot = Bot(name: "Fixture owner", backend: .hermes, hermesSessionID: id)
            let reviewer = Bot(name: "Fixture reviewer", backend: .mock)
            policyStore.bots = [policyBot, reviewer]
            for try await event in stream { switch event {
            case .token(let token): kinds.append("token"); reply += token
            case .replace(let text): kinds.append("replace"); reply = text
            case .status, .tool, .steer: kinds.append("status")
            case .subAgent: kinds.append("subagent")
            case .approval(let request):
                kinds.append("approval"); approvalCount += 1
                var scoped = request; scoped.botID = policyBot.id
                if approvalCount == 1 {
                    policyBot.approvalMode = .rules; policyBot.approvalRules = [.init(name: "Fixture read", actionPattern: "command", commandPattern: "cat /tmp/*", outcome: .allow)]
                    await policyStore.routeApproval(scoped, for: policyBot, backend: backend)
                    guard policyBot.approvalAudit.contains(where: { $0.approvalID == scoped.id && $0.outcome == .approved }) else { throw BackendError.unavailable("Fixture auto-approval did not resolve.") }
                    print("Hermes integration: auto-approved request=\(request.requestID ?? "missing")")
                } else {
                    policyBot.approvalMode = .reviewer; policyBot.reviewerBotID = reviewer.id
                    await policyStore.routeApproval(scoped, for: policyBot, backend: backend)
                    guard policyStore.approvals.contains(where: { $0.id == scoped.id }) else { throw BackendError.unavailable("Fixture destructive floor did not escalate.") }
                    guard policyBot.approvalAudit.contains(where: { $0.approvalID == scoped.id && $0.outcome == .asked && $0.decidedBy == "system" }) else { throw BackendError.unavailable("Fixture destructive-floor audit attribution was incorrect.") }
                    policyStore.decide(scoped, approved: false)
                    for _ in 0..<100 where policyStore.approvals.contains(where: { $0.id == scoped.id }) { try await Task.sleep(for: .milliseconds(10)) }
                    guard !policyStore.approvals.contains(where: { $0.id == scoped.id }) else { throw BackendError.unavailable("Escalated fixture approval was not resolved by the user path.") }
                    print("Hermes integration: destructive-floor-escalated request=\(request.requestID ?? "missing")")
                }
                approvalResolved = approvalCount >= 2
                if approvalCount == 2, env["HERMES_TEST_CANCEL"] == "1" { stopRequested = try await backend.cancel(sessionID: id) == .requested }
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
        WindowGroup(AppConstants.name, id: ContentView.windowID) {
            ContentView()
                .environmentObject(store)
                .defaultAppStorage(store.defaults)
                .preferredColorScheme(AppTheme.colorScheme(for: snapshotAppearance ?? appearance))
                .frame(minWidth: 980, minHeight: 620)
        }
            .defaultSize(width: 1120, height: 760)
            .windowStyle(.hiddenTitleBar)
            .commands { AppCommands(store: store, updater: updater) }
        WindowGroup("Computer", id: ComputerWindow.id, for: UUID.self) { $botID in
            ComputerWindow(botID: botID)
                .environmentObject(store)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
                .tint(AppTheme.accentColor(for: accent))
                .frame(minWidth: 800, minHeight: 560)
        }
            .defaultSize(width: 1280, height: 820)
        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
        }.windowResizability(.contentSize)
        // P38 C: live voice with ChatGPT, opened from a chat header or Settings → Voice.
        Window("Voice with ChatGPT", id: VoiceChatView.windowID) {
            VoiceChatView()
                .environmentObject(store)
                .defaultAppStorage(store.defaults)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
                .tint(AppTheme.accentColor(for: accent))
        }
        Window(SetupCopy.windowTitle, id: SetupView.windowID) {
            SetupView()
                .environmentObject(store)
                .defaultAppStorage(store.defaults)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
                .tint(AppTheme.accentColor(for: accent))
        }.windowResizability(.contentSize)
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updater)
                .preferredColorScheme(AppTheme.colorScheme(for: appearance))
        }
    }
}

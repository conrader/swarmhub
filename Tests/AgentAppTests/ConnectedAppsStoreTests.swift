import Foundation
import Testing
@testable import AgentApp

/// P38 B on main: a Hermes chat turn goes through the connected-apps loop, the app action is a P37 card that always asks,
/// receipts and full results survive a restart, and app connections sign in with main's P36 SwarmHub account.
@MainActor @Test func connectedAppsChatTurnAsksOnACardAndRecordsTheResult() async throws {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    let backend = AppRequestBackend()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Mail", backend: .hermes, hermesSessionID: "existing-chat")
    bot.approvalMode = .rules; bot.approvalRules = [.init(name: "Allow all", actionPattern: "*", commandPattern: "*", outcome: .allow)]
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.send(text: "Read my inbox"))
    try await waitUntil { !store.approvals.isEmpty }
    let card = store.approvals[0]
    #expect(store.isAppAction(card) && card.botID == bot.id && card.routeNote == "App actions always ask you.")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") }, "nothing runs before the card is answered")
    store.decide(card, approved: true)
    try await waitUntil { store.isIdle }
    #expect(bot.messages.last { $0.role == .assistant }?.content == "Your inbox contains one message.")
    #expect(bot.messages.contains { $0.role == .system && $0.content == "Approved: Fetch emails" })
    #expect(bot.approvalAudit.map(\.outcome).suffix(2) == [.asked, .approved])
    let receipt = try #require(apps.receipts.last)
    #expect(receipt.state == .succeeded && receipt.botID == bot.id && receipt.tool == "GMAIL_FETCH_EMAILS")
    let resultID = try #require(receipt.resultID)
    let saved = String(decoding: try apps.results().read(resultID, botID: bot.id), as: UTF8.self)
    #expect(saved.contains("synthetic inbox") && !saved.contains("never-copy-provider-token"))
    #expect(throws: ComposioError.self) { try apps.results().read(resultID, botID: UUID()) }
    #expect(await backend.recorded().count == 3)
}

@MainActor @Test func connectedAppsReceiptsAfterRestartNeverLookPendingOrRunning() throws {
    let directory = temporaryStore().deletingLastPathComponent()
    let apps = ConnectedAppsStore(directory: directory, keyStore: InMemoryKeyStore())
    let bot = UUID()
    let waiting = ToolExecutionReceipt(id: UUID(), botID: bot, sessionID: "chat", tool: "GMAIL_SEND_EMAIL", account: "ca_work", arguments: "{}")
    var running = waiting; running.id = UUID(); running.state = .executing
    try apps.record(waiting); try apps.record(running)
    let restored = ConnectedAppsStore(directory: directory, keyStore: InMemoryKeyStore())
    #expect(restored.receipts.map(\.state) == [.declined, .unknown])
    #expect(restored.receipts.map(\.stateLabel) == ["Declined", "Outcome unknown"])
}

@MainActor @Test func connectedAppsSignInUsesTheSwarmHubAccount() async throws {
    let keys = InMemoryKeyStore()
    let center = ReportsCenter(fileURL: nil, keyStore: keys)
    let (host, session) = MockHermesProtocol.serve { request in
        request.url!.path.hasSuffix("/v1/auth/start") ? (503, ["detail": "not configured"]) : (404, [:])
    }
    center.session = session; center.openURL = { _ in Issue.record("no browser in tests") }; center.sleep = { _ in }
    let service = SwarmHubService(baseURL: URL(string: "https://\(host)/swarmhub")!, session: session)
    let identity = SwarmHubAccountIdentity(center: center, service: service)
    await #expect(throws: ComposioProvisioningError.signInUnavailable) { try await identity.accessToken() }
    #expect(ComposioProvisioningError.signInUnavailable.localizedDescription == "Sign-in to SwarmHub is not set up on the server yet.")
    center.store(SwarmHubToken(accessToken: "synthetic-swarmhub-token", expiresAt: .now.addingTimeInterval(3600)))
    let before = MockHermesProtocol.recorded(host).count
    #expect(try await identity.accessToken() == "synthetic-swarmhub-token")
    #expect(MockHermesProtocol.recorded(host).count == before, "a stored sign-in is reused without a request")
}

@MainActor @Test func backgroundInboxActionsBecomeCardsAndAnswersGoToSwarmHub() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Worker", backend: .hermes); store.bots = [bot]
    let botID = bot.id.uuidString.lowercased()
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url!.path.hasSuffix("/inbox") {
            return (200, ["requests": [["id": "req_1", "bot_id": botID, "tool": "SLACK_SEND_MESSAGE", "account": "ca_slack",
                                        "arguments": ["text": "hello"], "state": "awaitingApproval"],
                                       ["id": "req_2", "bot_id": UUID().uuidString, "tool": "GMAIL_SEND_EMAIL", "state": "awaitingApproval"]]])
        }
        return (200, ["state": "approved"])
    }
    let identity = FakeSwarmHubIdentity()
    let client = BackgroundExecutionClient(baseURL: URL(string: "https://\(host)/swarmhub/")!, identity: identity, session: session)
    let rows = try await store.refreshBackgroundInbox(client: client)
    #expect(rows.count == 2 && store.approvals.count == 1, "an unknown bot's action makes no card")
    let card = store.approvals[0]
    #expect(card.actionKind == "background.SLACK_SEND_MESSAGE" && card.requestID == "req_1" && card.command?.contains("hello") == true)
    try await store.refreshBackgroundInbox(client: client)
    #expect(store.approvals.count == 1, "the same action is not added twice")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-user-session" })
}

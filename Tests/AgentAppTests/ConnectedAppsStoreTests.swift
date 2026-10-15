import Foundation
import Testing
@testable import AgentApp

/// P38 B on main: a Hermes chat turn goes through the connected-apps loop, the app action is a P37 card that always asks,
/// receipts and full results survive a restart, and the SwarmHub service is reached with this Mac's install key (P40).
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
    let client = BackgroundExecutionClient(baseURL: URL(string: "https://\(host)/swarmhub/")!, credential: FakeSwarmHubInstall(), session: session)
    let rows = try await store.refreshBackgroundInbox(client: client)
    #expect(rows.count == 2 && store.approvals.count == 1, "an unknown bot's action makes no card")
    let card = store.approvals[0]
    #expect(card.actionKind == "background.SLACK_SEND_MESSAGE" && card.requestID == "req_1" && card.command?.contains("hello") == true)
    try await store.refreshBackgroundInbox(client: client)
    #expect(store.approvals.count == 1, "the same action is not added twice")
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Install ins_synthetic.synthetic-install-key" })
}

@Test func swarmhubLinksAreOnlyTheSignInReturnAndTheBuildCarriesTheSchemeAndService() throws {
    #expect(AppStore.isSignInReturn(URL(string: "swarmhub://app-connections/sign-in?state=s&code=c")!))
    for other in ["https://app-connections/sign-in", "swarmhub://elsewhere/sign-in", "swarmhub://app-connections/other", "swarmhub://user:pw@app-connections/sign-in"] {
        #expect(!AppStore.isSignInReturn(URL(string: other)!), "\(other)")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let plist = try #require(NSDictionary(contentsOf: root.appending(path: "Resources/Info.plist")) as? [String: Any])
    let schemes = (plist["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    #expect(schemes == ["swarmhub"])
    let service = try #require((plist["SWComposioProvisioningURL"] as? String).flatMap(URL.init(string:)))
    #expect(ComposioProvisioningClient.validServiceURL(service))
    #expect(ComposioProvisioningClient.configuredURL(environment: ["SWARMHUB_COMPOSIO_SERVICE_URL": "https://example.test/swarmhub/"])?.host == "example.test")
    #expect(ComposioProvisioningClient.configuredURL(environment: ["SWARMHUB_COMPOSIO_SERVICE_URL": "http://example.test/"]) == nil, "only plain https")
}

@MainActor @Test func connectedAppsServiceHealthSaysWhenSignInIsNotSetUp() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    // A test run has no Info.plist service: nothing is checked and nothing is claimed.
    #expect(store.connectedAppsServiceURL == nil && !store.connectedApps.isAvailable)
    await store.checkConnectedAppsService()
    #expect(store.connectedApps.serviceNote == nil)
}

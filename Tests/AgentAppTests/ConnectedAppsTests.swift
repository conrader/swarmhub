import Foundation
import Testing
@testable import AgentApp

@MainActor @Test func composioSettingsPersistIdentityAndGrantsWithoutCredentials() async throws {
    let (apps, _, directory) = composioFixture()
    await apps.refresh()
    let bot = UUID(); let first = apps.accounts[0]; let second = apps.accounts[1]
    apps.setAllowed(true, account: first, botID: bot)
    apps.setAllowed(true, account: second, botID: bot)
    #expect(apps.grants(for: bot) == [first.id, second.id].sorted(), "P48: several accounts of one app stay on together")
    let bytes = try Data(contentsOf: directory.appending(path: "connected-apps.json"))
    let saved = String(decoding: bytes, as: UTF8.self)
    #expect(!saved.contains(syntheticComposioKey) && !saved.contains("provider-token") && !saved.contains("refresh-token"))
    let restored = ConnectedAppsStore(directory: directory, keyStore: InMemoryKeyStore())
    #expect(restored.configuration == apps.configuration)
    let otherBot = UUID()
    #expect(restored.grants(for: otherBot).isEmpty)
    apps.removeBot(bot)
    #expect(apps.grants(for: bot).isEmpty)
}

@MainActor @Test func composioRotationClearsGrantsAndImportedRequestsDoNotGrantAccess() async throws {
    let (apps, _, _) = composioFixture(); await apps.refresh()
    let bot = Bot(name: "Imported", requestedConnectorIDs: ["google-drive", "slack"])
    #expect(apps.grants(for: bot.id).isEmpty)
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(apps.saveKey("synthetic-new-project-key"))
    #expect(apps.grants(for: bot.id).isEmpty && apps.accounts.isEmpty)
}

@MainActor @Test func composioExpiredSelectedAccountNeverFallsBack() async throws {
    let expired = ComposioAccount(try JSONDecoder().decode(ComposioValue.self, from: JSONSerialization.data(withJSONObject: composioAccount(status: "EXPIRED"))))!
    let (apps, _, directory) = composioFixture { _ in (200, ["items": [composioAccount(status: "EXPIRED"), composioAccount("ca_personal")]]) }
    let bot = UUID()
    var configuration = apps.configuration; configuration.grants[bot.uuidString] = [expired.id]
    try JSONEncoder().encode(configuration).write(to: directory.appending(path: "connected-apps.json"))
    let (host, session) = MockHermesProtocol.serve { _ in (200, ["items": [composioAccount(status: "EXPIRED"), composioAccount("ca_personal")]]) }
    let restored = ConnectedAppsStore(directory: directory, keyStore: InMemoryKeyStore([ConnectedAppsStore.keyAccount: syntheticComposioKey]), session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!)
    await #expect(throws: ComposioError.self) { try await restored.scope(for: bot) }
}

@MainActor @Test func composioToolLoopUsesLocalApprovalAndKeepsSecretsOutOfBackend() async throws {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    let backend = AppRequestBackend()
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "existing-hermes-chat", systemPrompt: "Your persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: backend, apps: apps)
    var text = ""; var approvals = 0
    for try await event in stream {
        switch event {
        case .approval(let approval):
            approvals += 1
            #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") })
            #expect(approval.command?.contains("ca_work") == true && approval.command?.contains("is:unread") == true)
            #expect(await apps.approvals.decide(approval.id, approved: true))
        case .token(let value): text += value
        default: break
        }
    }
    #expect(approvals == 1 && text == "Your inbox contains one message.")
    let requests = await backend.recorded()
    #expect(requests.count == 3 && requests.allSatisfy { $0.sessionID == "existing-hermes-chat" })
    let input = requests.map { $0.systemPrompt + $0.messages.map(\.content).joined() }.joined()
    #expect(!input.contains(syntheticComposioKey) && !input.contains("provider-token") && !input.contains("refresh-token"))
    let executions = MockHermesProtocol.recorded(host).filter { $0.url!.path.hasSuffix("/execute") }
    // P48: one granted account is a single-account session: its pin chooses the account, execute names none.
    #expect(executions.count == 1 && composioBody(executions[0])["account"] == nil)
}

@MainActor @Test func composioDeclineAndRevocationPreventExecution() async throws {
    for revoke in [false, true] {
        let (apps, host, _) = composioFixture(); await apps.refresh()
        let account = apps.accounts[0]; let botID = UUID(); apps.setAllowed(true, account: account, botID: botID)
        let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: AppRequestBackend(), apps: apps)
        var declined = ""; var failed = false
        do {
            for try await event in stream {
                if case .approval(let request) = event {
                    if revoke { apps.setAllowed(false, account: account, botID: botID) }
                    _ = await apps.approvals.decide(request.id, approved: revoke)
                }
                if case .token(let text) = event { declined += text }
            }
        } catch { failed = true }
        #expect(revoke ? failed : declined == "App action declined.")
        #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") })
    }
}

@MainActor @Test func composioNormalRepliesStreamWithoutContactingComposio() async throws {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    let before = MockHermesProtocol.recorded(host).count
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Hello")]), botID: botID, backend: AppRequestBackend(.normal), apps: apps)
    var text = ""; var chunks = 0
    for try await event in stream { if case .token(let value) = event { text += value; chunks += 1 } }
    #expect(text == "A normal streamed reply." && chunks > 1)
    #expect(MockHermesProtocol.recorded(host).count == before)
}

@MainActor @Test func composioUnknownToolsAndStepLimitFailWithoutExecution() async throws {
    for mode in [AppRequestBackend.Mode.unknownTool, .endlessSearch] {
        let (apps, host, _) = composioFixture(); await apps.refresh()
        let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
        let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: AppRequestBackend(mode), apps: apps, maximumSteps: 3)
        do { for try await _ in stream {}; Issue.record("Expected a bounded failure") } catch {}
        #expect(MockHermesProtocol.recorded(host).allSatisfy { !$0.url!.path.hasSuffix("/execute") })
    }
}

@Test func composioProtocolRejectsMalformedAndQuotedRequests() throws {
    let marker = "[[SWARMHUB_APP_REQUEST_123]]"
    #expect(try AppToolRequest.parse("Example: " + marker + "\n{}", marker: marker) == nil)
    #expect(throws: ComposioError.self) { try AppToolRequest.parse(marker + "\n{\"action\":\"execute\",\"tool\":\"COMPOSIO_REMOTE_WORKBENCH\",\"arguments\":{}}", marker: marker) }
    #expect(throws: ComposioError.self) { try AppToolRequest.parse(marker + "\n{\"action\":\"search\",\"query\":\"gmail\",\"account\":\"foreign\"}", marker: marker) }
    #expect(throws: ComposioError.self) { try AppToolRequest.parse(marker + "\n{\"action\":\"search\",\"query\":\"gmail\"} extra text", marker: marker) }
}

@MainActor @Test func composioStopCancelsApprovalWaiter() async throws {
    let broker = AppToolApprovalBroker()
    let request = ApprovalRequest(id: UUID(), title: "Use app", summary: "test", draft: nil, command: "app action")
    let events = AwaitableLog<AgentEvent>()
    let task = Task { try await broker.wait(request) { events.append($0) } }
    try await events.wait { !$0.isEmpty }
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await broker.decide(request.id, approved: true) == false)
}

@MainActor @Test func composioHistoryHidesProtocolAndMergesFinalAnswer() {
    let question = ChatMessage(role: .user, content: "Read my inbox")
    let answer = ChatMessage(role: .assistant, content: "One email.")
    let server: [BackendMessage] = [
        .init(role: "user", content: question.content),
        .init(role: "assistant", content: "[[SWARMHUB_APP_REQUEST_\(UUID().uuidString)]]\n{\"action\":\"search\",\"query\":\"gmail\"}"),
        .init(role: "user", content: ConnectedAppsChat.resultPrefix + "{}"),
        .init(role: "assistant", content: answer.content),
        .init(role: "user", content: "Next question"), .init(role: "assistant", content: "Next reply")
    ]
    #expect(AppStore.mergeHermesHistory(local: [question, answer], server: server)?.map(\.content) == ["Read my inbox", "One email.", "Next question", "Next reply"])
    #expect(AppStore.mergeHermesHistory(local: [], server: server)?.count == 4)
}

@MainActor @Test func composioApprovalsStayLocalAndAlwaysAskDespiteAllowRules() async throws {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Apps", backend: .hermes, approvalMode: .rules, approvalRules: [.init(name: "Allow", actionPattern: "*", commandPattern: "*", outcome: .allow)])
    store.bots = [bot]
    let request = ApprovalRequest(id: UUID(), title: "Send email", summary: "Gmail", draft: nil, command: "{}", botID: bot.id, sessionID: "chat", actionKind: "composio.GMAIL_SEND_EMAIL")
    let events = AwaitableLog<AgentEvent>()
    store.connectedApps.localApprovals[request.id] = .chat
    let waiting = Task { try await store.connectedApps.approvals.wait(request) { events.append($0) } }
    try await events.wait { !$0.isEmpty }
    await store.routeApproval(request, for: bot, backend: backend)
    #expect(store.approvals.map(\.id) == [request.id])
    #expect(bot.approvalAudit.last?.outcome == .asked)
    store.decide(request, approved: true)
    #expect(try await waiting.value)
    try await waitUntil { store.approvals.isEmpty }
    #expect(bot.approvalAudit.last?.outcome == .approved)
    #expect(!backend.calls.all.contains { $0.hasPrefix("approval") }, "App approval must not be sent to Hermes")
    // A bot server's approval that only names itself an app action is routed like any other box approval. The audit's
    // narrower auto-approval (reviewerMustEscalate) asks the user whenever the action says "send", even under the allow line.
    let forged = ApprovalRequest(id: UUID(), title: "Forged", summary: "x", draft: nil, command: "cat /tmp/x", botID: bot.id, sessionID: "chat", actionKind: "composio.GMAIL_SEND_EMAIL")
    #expect(!store.isAppAction(forged))
    await store.routeApproval(forged, for: bot, backend: backend)
    #expect(store.approvals.contains { $0.id == forged.id } && bot.approvalAudit.last?.outcome == .asked)
    #expect(!backend.calls.all.contains { $0.hasPrefix("approval") }, "nothing is auto-approved on the box")
}

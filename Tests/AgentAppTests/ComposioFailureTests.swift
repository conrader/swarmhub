import Foundation
import Testing
@testable import AgentApp

/// P48 item 1: Composio's 400 body reaches the chat and the bot (no secrets), and execute matches the v3.1 docs:
/// a single-account session names no `account`, a multi-account one does.
private func failureBody() -> [String: Any] { ["error": [
    "message": "Tool GITHUB_GET_THE_AUTHENTICATED_USER requires an account selection \(syntheticComposioKey) access_token=never-copy-provider-token",
    "code": 1_400, "slug": "ToolRouter_InvalidAccount", "status": 400, "request_id": "req_synthetic_1",
    "suggested_fix": "Pass a connected account that belongs to this session.", "errors": ["never shown"]]] }

@Test func composioFailureKeepsMessageSlugAndFixWithoutSecrets() throws {
    let data = try JSONSerialization.data(withJSONObject: failureBody())
    let failure = try #require(ComposioFailure(status: 400, body: data, key: syntheticComposioKey))
    #expect(failure.slug == "ToolRouter_InvalidAccount" && failure.requestID == "req_synthetic_1")
    #expect(failure.line.hasPrefix("Composio: Tool GITHUB_GET_THE_AUTHENTICATED_USER requires an account selection"))
    #expect(failure.line.contains("(ToolRouter_InvalidAccount) Pass a connected account that belongs to this session."))
    #expect(!failure.line.contains(syntheticComposioKey) && !failure.line.contains("never-copy") && !failure.line.contains("never shown"))
    #expect(failure.logLine.contains("HTTP 400") && failure.logLine.contains("req_synthetic_1"))
    let long = try JSONSerialization.data(withJSONObject: ["error": ["message": String(repeating: "m", count: 2_000), "slug": String(repeating: "s", count: 900)]])
    let capped = try #require(ComposioFailure(status: 400, body: long, key: ""))
    #expect(capped.message.count == 300 && capped.slug?.count == 300)
    #expect(ComposioFailure(status: 502, body: Data("<html>".utf8), key: "") == nil, "no body → the plain HTTP status error")
}

@MainActor @Test func composioExecute400ReturnsToTheBotAndTheChat() async throws {
    let (apps, host, _) = composioFixture { request in
        request.url!.path.hasSuffix("/execute") ? (400, failureBody()) : composioHandler(request)
    }
    await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    let backend = AppRequestBackend()
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: backend, apps: apps)
    var lines: [String] = []; var text = ""
    for try await event in stream {
        switch event {
        case .approval(let approval): _ = await apps.approvals.decide(approval.id, approved: true)
        case .appError(let line): lines.append(line)
        case .token(let value): text += value
        default: break
        }
    }
    #expect(text == "Your inbox contains one message.", "the turn goes on after the failure")
    #expect(lines.count == 1 && lines[0].contains("Gmail · Send email failed:") && lines[0].contains("ToolRouter_InvalidAccount") && lines[0].contains("requires an account selection"))
    let calls = await backend.recorded()
    let result = try #require(calls.last?.messages.last?.content)
    #expect(result.hasPrefix(ConnectedAppsChat.resultPrefix) && result.contains("ToolRouter_InvalidAccount") && result.contains("requires an account selection"))
    for shown in lines + [result] { #expect(!shown.contains(syntheticComposioKey) && !shown.contains("never-copy")) }
    #expect(apps.receipts.last?.state == .failed && apps.receipts.last?.stateLabel == "Failed")
    #expect(MockHermesProtocol.recorded(host).filter { $0.url!.path.hasSuffix("/execute") }.count == 1, "never retried")
}

@MainActor @Test func composioSearchFailureAlsoReturnsAResult() async throws {
    let (apps, _, _) = composioFixture { request in
        request.url!.path.hasSuffix("/search") ? (500, ["error": ["message": "Search is down", "slug": "Internal"]]) : composioHandler(request)
    }
    await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    let backend = AppRequestBackend(.normalAfterSearch)
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: backend, apps: apps)
    var lines: [String] = []
    for try await event in stream { if case .appError(let line) = event { lines.append(line) } }
    #expect(lines == ["App request failed: Composio: Search is down (Internal)"])
    #expect(await backend.recorded().last?.messages.last?.content.contains("Search is down (Internal)") == true)
}

@MainActor @Test func appErrorBecomesAWarningLineInTheChat() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .hermes); store.bots = [bot]
    let assistant = ChatMessage(role: .assistant, content: ""); bot.messages.append(assistant)
    let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
        continuation.yield(.appError("Get the authenticated user failed. Composio: Bad request (ToolRouter_InvalidAccount)"))
        continuation.yield(.token("It failed.")); continuation.yield(.completed); continuation.finish()
    }
    _ = try await store.consumeTurn(stream, assistant: assistant, bot: bot, sessionID: "chat", backend: AppRequestBackend(.normal), in: bot) { _ in }
    #expect(bot.messages.contains { $0.role == .system && $0.content == "Jarvis: Get the authenticated user failed. Composio: Bad request (ToolRouter_InvalidAccount)" })
}

@Test func composioSessionAndExecuteMatchTheDocs() async throws {
    let (host, session) = MockHermesProtocol.serve(composioHandler)
    let client = ComposioClient(apiKey: syntheticComposioKey, session: session, baseURL: URL(string: "https://\(host)/api/v3.1/")!)
    _ = try await client.createSession(userID: "u", toolkits: ["gmail"], accounts: ["gmail": ["ca_work"]])
    _ = try await client.execute(sessionID: "trs_synthetic", tool: "GMAIL_SEND_EMAIL", arguments: .object([:]))
    _ = try await client.createSession(userID: "u", toolkits: ["gmail", "github"], accounts: ["gmail": ["ca_work", "ca_personal"], "github": ["ca_gh"]])
    _ = try await client.execute(sessionID: "trs_synthetic", tool: "GMAIL_SEND_EMAIL", arguments: .object([:]), account: "ca_personal")
    _ = try await client.createSession(userID: "u", toolkits: ["gmail"], addingAccount: true)
    let requests = MockHermesProtocol.recorded(host).map(composioBody)
    #expect(requests[0]["multi_account"] as? [String: Bool] == ["enable": false], "single-account: enable:false and no other multi-account key")
    #expect(requests[1]["account"] == nil)
    let multi = try #require(requests[2]["multi_account"] as? [String: Any])
    #expect(multi["enable"] as? Bool == true && multi["max_accounts_per_toolkit"] as? Int == 2 && multi["require_explicit_selection"] as? Bool == true)
    #expect((requests[2]["connected_accounts"] as? [String: [String]]) == ["gmail": ["ca_personal", "ca_work"], "github": ["ca_gh"]])
    #expect(requests[3]["account"] as? String == "ca_personal")
    let adding = try #require(requests[4]["multi_account"] as? [String: Any])
    #expect(adding["enable"] as? Bool == true && adding["max_accounts_per_toolkit"] as? Int == 10 && adding["require_explicit_selection"] == nil)
}

@Test func onlyARefusalCountsAsNotRun() {
    let refused = ComposioFailure(status: 400, body: Data(#"{"error":{"message":"bad"}}"#.utf8), key: "")!
    let crashed = ComposioFailure(status: 503, body: Data(#"{"error":{"message":"down"}}"#.utf8), key: "")!
    #expect(AppRequestFailure.answered(ComposioError.api(refused)) && AppRequestFailure.answered(ComposioError.http(409)))
    #expect(!AppRequestFailure.answered(ComposioError.api(crashed)) && !AppRequestFailure.answered(ComposioError.http(502)))
    #expect(!AppRequestFailure.answered(URLError(.timedOut)))
}

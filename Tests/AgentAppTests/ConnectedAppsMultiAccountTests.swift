import Foundation
import Testing
@testable import AgentApp

/// P48 item 2: several accounts of one app per bot. Composio is `MockHermesProtocol`; nothing reaches the network.
private final class Script: @unchecked Sendable {
    private let lock = NSLock(); private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return replies.isEmpty ? "Done." : replies.removeFirst() }
}

/// A bot that searches, then sends the given execute requests (`%@` is the marker), then answers.
private actor ScriptedBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    let script: Script; var calls: [AgentRequest] = []
    init(_ executes: [String]) { script = Script([#"{"action":"search","query":"read gmail"}"#] + executes) }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append(request)
        let marker = request.systemPrompt.components(separatedBy: "\n").first { $0.hasPrefix("[[SWARMHUB_APP_REQUEST_") }!
        let line = script.next(); let output = line.hasPrefix("{") ? marker + "\n" + line : line
        return AsyncThrowingStream { $0.yield(.token(output)); $0.yield(.completed); $0.finish() }
    }
    func recorded() -> [AgentRequest] { calls }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "scripted" }
    func stopTarget(sessionID: String) async throws -> StopTarget { .noActiveRun }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome { .noActiveRun }
}

private func execute(_ account: String?) -> String {
    #"{"action":"execute","tool":"GMAIL_FETCH_EMAILS","# + (account.map { #""account":"\#($0)","# } ?? "") + #""arguments":{"query":"is:unread"}}"#
}

@MainActor private func run(grant ids: [String], executes: [String]) async throws -> (approvals: [ApprovalRequest], requests: [URLRequest], bot: [AgentRequest], errors: [String]) {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    let botID = UUID()
    for id in ids { apps.setAllowed(true, account: try #require(apps.accounts.first { $0.id == id }), botID: botID) }
    let backend = ScriptedBackend(executes)
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: backend, apps: apps)
    var approvals: [ApprovalRequest] = []; var errors: [String] = []
    for try await event in stream {
        if case .approval(let approval) = event { approvals.append(approval); _ = await apps.approvals.decide(approval.id, approved: true) }
        if case .appError(let line) = event { errors.append(line) }
    }
    return (approvals, MockHermesProtocol.recorded(host), await backend.recorded(), errors)
}

@MainActor @Test func twoGmailsOnOneBotMakeAMultiAccountSessionAndTheNameChoosesTheAccount() async throws {
    let result = try await run(grant: ["ca_work", "ca_personal"], executes: [execute("CA_PERSONAL")])
    let session = composioBody(try #require(result.requests.first { $0.url!.path.hasSuffix("tool_router/session") }))
    #expect((session["connected_accounts"] as? [String: [String]])?["gmail"] == ["ca_personal", "ca_work"])
    let multi = try #require(session["multi_account"] as? [String: Any])
    #expect(multi["enable"] as? Bool == true && multi["max_accounts_per_toolkit"] as? Int == 2 && multi["require_explicit_selection"] as? Bool == true)
    let executions = result.requests.filter { $0.url!.path.hasSuffix("/execute") }
    #expect(executions.count == 1 && composioBody(executions[0])["account"] as? String == "ca_personal")
    #expect(result.approvals.map(\.summary) == ["Gmail · ca_personal"])
    // The bot sees its accounts by name, in the prompt and beside the discovered tools.
    #expect(result.bot[0].systemPrompt.contains(#"{"gmail":["ca_personal","ca_work"]}"#))
    #expect(result.bot[1].messages.last?.content.contains(#""accounts":{"gmail":["ca_personal","ca_work"]}"#) == true)
}

@MainActor @Test func anUngrantedOrUnknownNameIsRefusedWithTheNames() async throws {
    for name in ["ca_other", "Somebody else"] {
        let result = try await run(grant: ["ca_work", "ca_personal"], executes: [execute(name)])
        #expect(result.approvals.isEmpty && !result.requests.contains { $0.url!.path.hasSuffix("/execute") })
        #expect(result.errors.count == 1 && result.errors[0].contains(#""\#(name)" is not one of this bot's Gmail accounts. Use one of: "ca_personal", "ca_work"."#))
        #expect(result.bot.last?.messages.last?.content.contains("is not one of this bot's Gmail accounts") == true)
    }
    // A name that exists at Composio but is not granted to this bot is refused just the same.
    let single = try await run(grant: ["ca_work"], executes: [execute("ca_personal")])
    #expect(single.approvals.isEmpty && single.errors.first?.contains(#"Use one of: "ca_work"."#) == true)
}

@MainActor @Test func noNameWithTwoAccountsListsTheNamesWithoutGuessing() async throws {
    let result = try await run(grant: ["ca_work", "ca_personal"], executes: [execute(nil)])
    #expect(result.approvals.isEmpty && !result.requests.contains { $0.url!.path.hasSuffix("/execute") })
    #expect(result.errors == [#"App request failed. This bot has 2 Gmail accounts. Repeat the request with "account" set to one of: "ca_personal", "ca_work"."#])
}

@MainActor @Test func oneAccountIsASingleAccountSessionWithOrWithoutTheName() async throws {
    for name in [nil, "ca_work"] {
        let result = try await run(grant: ["ca_work"], executes: [execute(name)])
        let session = composioBody(try #require(result.requests.first { $0.url!.path.hasSuffix("tool_router/session") }))
        #expect(session["multi_account"] as? [String: Bool] == ["enable": false])
        #expect((session["connected_accounts"] as? [String: [String]])?["gmail"] == ["ca_work"])
        let executions = result.requests.filter { $0.url!.path.hasSuffix("/execute") }
        #expect(executions.count == 1 && composioBody(executions[0])["account"] == nil)
    }
}

@MainActor @Test func aBotCanHaveAtMostTenAccountsOfOneApp() async throws {
    let (apps, _, _) = composioFixture { request in
        request.url!.path.hasSuffix("connected_accounts") ? (200, ["items": (0..<11).map { composioAccount("ca_g\($0)") }]) : composioHandler(request)
    }
    await apps.refresh()
    let bot = UUID()
    for account in apps.accounts { apps.setAllowed(true, account: account, botID: bot) }
    #expect(apps.grants(for: bot).count == 10 && apps.error?.contains("at most 10") == true)
}

@MainActor @Test func aConnectForAnAppThatHasAnAccountAddsOne() async throws {
    let (apps, host, _) = composioFixture(); await apps.refresh()
    _ = await apps.connect("gmail")
    _ = await apps.connect("slack")
    let sessions = MockHermesProtocol.recorded(host).filter { $0.url!.path.hasSuffix("tool_router/session") }.map(composioBody)
    #expect((sessions[0]["multi_account"] as? [String: Any])?["enable"] as? Bool == true)
    #expect(sessions[1]["multi_account"] as? [String: Bool] == ["enable": false])
}

@Test func executeMayNameAnAccountButNothingElseMay() throws {
    let marker = "[[SWARMHUB_APP_REQUEST_1]]"
    #expect(try AppToolRequest.parse(marker + "\n" + execute("Work"), marker: marker)?.account == "Work")
    #expect(throws: ComposioError.self) { try AppToolRequest.parse(marker + "\n{\"action\":\"search\",\"query\":\"gmail\",\"account\":\"Work\"}", marker: marker) }
    #expect(throws: ComposioError.self) { try AppToolRequest.parse(marker + "\n{\"action\":\"execute\",\"tool\":\"GMAIL_FETCH_EMAILS\",\"account\":7,\"arguments\":{}}", marker: marker) }
}

@Test func aNameThatFitsTwoAccountsIsRefused() throws {
    let scope = ComposioRunScope(client: ComposioClient(apiKey: "k"), userID: "u", accounts: ["gmail": ["ca_a", "ca_b", "ca_c"]],
                                 labels: ["ca_a": "Work", "ca_b": "work", "ca_c": "Home"], revision: UUID())
    #expect(try AppAccountChoice.resolve("Work", toolkit: "gmail", appName: "Gmail", scope: scope) == "ca_a")
    #expect(try AppAccountChoice.resolve("home", toolkit: "gmail", appName: "Gmail", scope: scope) == "ca_c")
    #expect(try AppAccountChoice.resolve("ca_b", toolkit: "gmail", appName: "Gmail", scope: scope) == "ca_b")
    #expect(throws: AppAccountChoiceError.self) { try AppAccountChoice.resolve("WORK", toolkit: "gmail", appName: "Gmail", scope: scope) }
}

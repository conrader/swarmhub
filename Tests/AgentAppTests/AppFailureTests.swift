import Foundation
import Testing
@testable import AgentApp

/// P52 item 2: every app failure is logged by shape, named in the chat, returned to the bot, and does not end the turn or
/// the goal. Composio is `MockHermesProtocol`; nothing reaches the network.

private final class Replies: @unchecked Sendable {
    private let lock = NSLock(); private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func next() -> String { lock.lock(); defer { lock.unlock() }; return replies.isEmpty ? "Done." : replies.removeFirst() }
}

/// A bot that writes the given replies in order (`{…}` lines get the turn's marker; `{…}}` keeps its extra brace).
private actor ScriptedAppBot: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    let replies: Replies; var calls: [AgentRequest] = []
    init(_ replies: [String]) { self.replies = Replies(replies) }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append(request)
        let marker = request.systemPrompt.components(separatedBy: "\n").first { $0.hasPrefix("[[SWARMHUB_APP_REQUEST_") } ?? ""
        let line = replies.next(), output = line.hasPrefix("{") ? marker + "\n" + line : line
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

private let search = #"{"action":"search","query":"read gmail"}"#
private let fetch = #"{"action":"execute","tool":"GMAIL_FETCH_EMAILS","arguments":{"query":"is:unread"}}"#
private let secret = "never-shown-value-ca_secret_123"

@MainActor private func run(_ replies: [String], handler: @escaping MockHermesProtocol.Handler) async throws -> (errors: [String], text: String, bot: [AgentRequest], host: String) {
    let (apps, host, _) = composioFixture(handler: handler); await apps.refresh()
    let botID = UUID(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
    let backend = ScriptedAppBot(replies)
    let stream = try await ConnectedAppsChat.stream(.init(sessionID: "chat", systemPrompt: "persona", messages: [(role: "user", content: "Read my inbox")]), botID: botID, backend: backend, apps: apps)
    var errors: [String] = [], text = ""
    for try await event in stream {
        if case .appError(let line) = event { errors.append(line) }
        if case .token(let value) = event { text += value }
    }
    return (errors, text, await backend.recorded(), host)
}

@Test func theShapeNamesKeysTypesAndSizeButNeverValues() throws {
    let answer = Data(#"{"data":{"login":"\#(secret)"},"successful":true,"ca_secret_123":"x","log_id":"\#(secret)"}"#.utf8)
    let shape = AppFailureShape.describe(answer)
    #expect(shape == "object {data: object, log_id: string, successful: bool, 1 other key}, \(answer.count) bytes")
    let request = Data(#"{"action":"execute","arguments":{"query":"query { viewer { login } }"}}}"#.utf8)
    #expect(AppFailureShape.describe(request) == "not JSON, \(request.count) bytes, one JSON object followed by 1 byte more")
    #expect(AppFailureShape.describe(Data("<html>\(secret)</html>".utf8)).hasPrefix("not JSON, "))
    for text in [shape, AppFailureShape.describe(request)] { #expect(!text.contains(secret) && !text.contains("viewer")) }
}

@MainActor @Test func anUnreadableAnswerIsNamedInTheChatAndReturnedToTheBot() async throws {
    let result = try await run([search, fetch, "I could not read your inbox."]) { request in
        request.url!.path.hasSuffix("/execute") ? (200, Data(#"{"data":{"token":"\#(secret)"}}}"#.utf8)) : composioReadHandler(request)
    }
    #expect(result.text == "I could not read your inbox.", "the turn goes on")
    let line = try #require(result.errors.first)
    #expect(result.errors.count == 1)
    #expect(line.hasPrefix("Gmail · Fetch emails may not have finished: Composio's answer could not be read (not JSON, 53 bytes, one JSON object followed by 1 byte more)"))
    let returned = try #require(result.bot.last?.messages.last?.content)
    #expect(returned.hasPrefix(ConnectedAppsChat.resultPrefix) && returned.contains("could not be read") && returned.contains("\"tool\":\"Gmail · Fetch emails\""))
    for shown in [line, returned] { #expect(!shown.contains(secret) && !shown.contains("token")) }
}

@MainActor @Test func anAnswerWithoutTheExpectedFieldsShowsItsShape() async throws {
    let result = try await run([search, "Search did not work."]) { request in
        request.url!.path.hasSuffix("/search") ? (200, ["result": ["session": secret], "items": [1, 2]]) : composioReadHandler(request)
    }
    #expect(result.errors == ["App request failed: Composio's answer could not be read (object {items: array(2), result: object})."])
    #expect(result.text == "Search did not work.")
}

@MainActor @Test func aRequestWithTextAfterItsJSONGoesBackToTheBotNotAsComposios() async throws {
    // P54: stray `}` after the object are trimmed (`StaleMarkerTests`); other text after it is still refused before any Composio call.
    let result = try await run([search, fetch + " please", fetch, "Your inbox contains one message."], handler: composioReadHandler)
    #expect(result.errors == ["App request failed: SwarmHub could not read the app request: it is not JSON, 89 bytes, one JSON object followed by 6 bytes more. Send one JSON object exactly in the format shown."])
    #expect(result.text == "Your inbox contains one message.", "the bot resent it and the turn finished")
    #expect(MockHermesProtocol.recorded(result.host).filter { $0.url!.path.hasSuffix("/execute") }.count == 1, "only the readable request ran")
    #expect(result.bot[2].messages.last?.content.contains("could not read the app request") == true)
}

@MainActor @Test func aServerErrorWithoutABodyIsReturnedToo() async throws {
    let result = try await run([search, fetch, "The connection dropped."]) { request in
        request.url!.path.hasSuffix("/execute") ? (599, Data()) : composioReadHandler(request)
    }
    #expect(result.errors.count == 1 && result.errors[0].hasPrefix("Gmail · Fetch emails may not have finished: "))
    #expect(result.text == "The connection dropped.")
}

@MainActor @Test func aGoalSurvivesAnAppFailureTheBotWasToldAbout() async throws {
    let (apps, _, _) = composioFixture { request in
        request.url!.path.hasSuffix("/execute") ? (200, Data("not json".utf8)) : composioReadHandler(request)
    }
    await apps.refresh()
    let backend = ScriptedAppBot([search, fetch, "The inbox could not be read; trying later.", "Round two."])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps; store.defaults.set(2, forKey: GoalProtocol.roundsKey)
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat")
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.submitComposer(text: "/goal keep the inbox tidy"))
    try await waitUntil { store.goal(in: bot)?.state == .ended }
    #expect(store.goal(in: bot)?.round == 2, "the second round was sent")
    #expect(store.goal(in: bot)?.endReason == "Goal stopped: all 2 rounds used")
    #expect(bot.messages.contains { $0.role == .system && $0.content.hasPrefix("Plainsay: Gmail · Fetch emails may not have finished: Composio's answer could not be read") })
    #expect(!bot.messages.contains { $0.content == "Goal stopped: the last turn failed" })
}

@MainActor @Test func aFailureLineNeverReadsAsEarlierThanTheApprovalBeforeIt() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Plainsay", backend: .hermes); store.bots = [bot]
    let reply = ChatMessage(role: .assistant, content: ""); bot.messages = [ChatMessage(role: .user, content: "go"), reply, ChatMessage(role: .system, content: "Approved: Get the authenticated user")]
    store.addWarning("Plainsay: App request failed: x", in: bot, after: reply)
    #expect(bot.messages.map(\.content).suffix(2) == ["Approved: Get the authenticated user", "Plainsay: App request failed: x"])
}

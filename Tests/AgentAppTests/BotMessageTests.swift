import Foundation
import Testing
@testable import AgentApp

// P34 D4–D7: bot-msg steps parsed from commands, the thread loaded from the recipient (or the sender's steps), arrivals
// from session lists, the sidebar badge, the Activity list and ⌘K rows. Synthetic only.

private let script = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg"

// MARK: Step parsing

@Test(arguments: [
    ("\(script) --from grok-jarvis --to grok-infra -- \"Is /data above 80%?\"", "grok-infra", "grok-jarvis", "Is /data above 80%?", false),
    ("\(script) --from grok-jarvis --to grok-infra -- 'It'\\''s down, can you \"check\"?'", "grok-infra", "grok-jarvis", "It's down, can you \"check\"?", false),
    ("cd /tmp && \(script) --to=grok-infra --no-wait -- \"Restart \\\"backup\\\" \\$NOW\" && echo done", "grok-infra", nil, "Restart \"backup\" $NOW", true),
    ("bot-msg --to infra --wait 60 -- Please check the disk", "infra", nil, "Please check the disk", false),
    ("/usr/bin/env sh ./scripts/bot-msg --from a --to default -- \"multi\nline\"", "default", "a", "multi\nline", false),
    ("bot-msg --to infra -- \"a; b && c\" | tee /tmp/out", "infra", nil, "a; b && c", false)
] as [(String, String, String?, String, Bool)])
func botMsgCommandsParse(_ command: String, _ to: String, _ from: String?, _ text: String, _ noWait: Bool) throws {
    let call = try #require(BotMessageCall.parse(command: command))
    #expect(call == BotMessageCall(to: to, from: from, text: text, noWait: noWait))
}

@Test func otherCommandsAreNotBotMessages() {
    #expect(BotMessageCall.parse(command: "hermes -p grok-infra chat -c 'Bot Chat' --create-if-missing -Q --query-file -") == nil)
    #expect(BotMessageCall.parse(command: "echo 'bot-msg --to infra -- hi'") == nil, "a quoted mention is text")
    #expect(BotMessageCall.parse(command: "bot-msg -- \"no recipient\"") == nil)
    #expect(BotMessageCall.parse(command: "bot-msg --to '../etc' -- x") == nil)
    #expect(BotMessageCall.parse(command: "cat bot-msg-notes.txt") == nil)
}

@Test func headerAndResultsAreRead() {
    #expect(BotMessageCall.strippingHeader("[Message from grok-jarvis via SwarmHub]\nIs the disk full?") == ("grok-jarvis", "Is the disk full?"))
    #expect(BotMessageCall.strippingHeader("plain") == (nil, "plain"))
    #expect(BotMessageCall.reply(fromResult: #"{"output":"Disk at 62%.\n","exit_code":0}"#) == "Disk at 62%.")
    #expect(BotMessageCall.reply(fromResult: "swarmhub-from-grok-jarvis\n") == "swarmhub-from-grok-jarvis")
    #expect(BotMessageCall.reply(fromResult: "  ") == nil && BotMessageCall.reply(fromResult: nil) == nil)
}

@Test func hermesToolEventsCarryTheCommandAndResult() {
    let backend = HermesBackend(baseURL: URL(string: "http://127.0.0.1:8642/v1")!, apiKey: "", profile: "grok-jarvis")
    let started = backend.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "c1", "preview": "bot-msg --to grok-infra",
                                                      "args": ["command": "\(script) --from grok-jarvis --to grok-infra -- \"Disk?\""]])
    #expect(started.command?.hasSuffix("-- \"Disk?\"") == true)
    let stringArgs = backend.nativeTool("tool.started", ["tool_name": "terminal", "args": #"{"command":"bot-msg --to x -- hi"}"#])
    #expect(stringArgs.command == "bot-msg --to x -- hi")
    #expect(backend.nativeTool("tool.started", ["tool_name": "terminal", "args": ["command": "ls -la"]]).command == nil, "only bot-msg commands are kept")
    let done = backend.nativeTool("tool.completed", ["tool_name": "terminal", "tool_call_id": "c1", "result": ["output": "62%", "exit_code": 0]])
    #expect(done.command == nil && BotMessageCall.reply(fromResult: done.result) == "62%")

    var activity = ToolActivity(), now = Date(timeIntervalSince1970: 1_000)
    activity.apply(started, at: now)
    activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "notes.md", callID: "c2"), at: now)
    activity.apply(done, at: now.addingTimeInterval(3))
    #expect(activity.steps[0].botMessage == BotMessageCall(to: "grok-infra", from: "grok-jarvis", text: "Disk?", reply: "62%"))
    #expect(activity.steps[1].botMessage == nil)
    // An old store without the field still loads.
    let old = try? JSONDecoder().decode(ToolStep.self, from: Data(#"{"name":"terminal","startedAt":0,"failed":false}"#.utf8))
    #expect(old != nil && old?.botMessage == nil)
}

// MARK: Store fixtures

/// Jarvis (`grok-jarvis`) wrote to Infra (`grok-infra`) in one reply; one synthetic Hermes connection for both.
@MainActor private func threadStore(rows: [[String: Any]] = [], messages: [[String: Any]] = [], connected: Bool = true) -> (AppStore, Bot, Bot, String) {
    let list = (try? JSONSerialization.data(withJSONObject: ["data": rows])) ?? Data()
    let thread = (try? JSONSerialization.data(withJSONObject: ["data": messages])) ?? Data()
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path == "/api/sessions" { return .init(status: 200, body: list) }
        if path == "/api/sessions/swarmhub-from-grok-jarvis/messages" { return .init(status: 200, body: thread) }
        return .json(404, ["error": "no route"])
    }
    var store: AppStore!
    store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { bot in
        if !connected, bot.hermesProfile == "grok-infra" { throw BackendError.unavailable("not connected") }
        return hermes
    }, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    let infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")
    let reply = ChatMessage(role: .assistant, content: "Infra says the disk is at 62%.", createdAt: Date(timeIntervalSince1970: 2_000))
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1", command: "\(script) --from grok-jarvis --to grok-infra -- \"How full is /data?\""),
                   at: Date(timeIntervalSince1970: 2_000))
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c1", result: #"{"output":"62%, fine."}"#), at: Date(timeIntervalSince1970: 2_004))
    reply.activity = activity
    jarvis.messages = [ChatMessage(role: .user, content: "ask infra about the disk", createdAt: Date(timeIntervalSince1970: 1_990)), reply]
    store.bots = [jarvis, infra]; store.selectedBot = jarvis
    store.botMessages.autoLoad = false
    return (store, jarvis, infra, host)
}

private let key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")

// MARK: Thread loading

@Test @MainActor func threadOpensFromTheStepsThenFillsFromTheRecipient() async {
    let rows: [[String: Any]] = [
        ["id": 1, "role": "user", "content": "[Message from grok-jarvis via SwarmHub]\nHow full is /data?", "created_at": 2_001.0],
        ["id": 2, "role": "assistant", "content": "62%, fine.", "created_at": 2_003.0],
        ["id": 3, "role": "user", "content": "[Message from grok-jarvis via SwarmHub]\nAnd /home?", "created_at": 2_100.0],
        ["id": 4, "role": "assistant", "content": "40%.", "created_at": 2_102.0]
    ]
    let (store, jarvis, _, host) = threadStore(messages: rows)
    let reply = jarvis.messages[1]
    #expect(store.threadKey(for: reply.activity!.steps[0].botMessage!, in: reply) == key)
    let known = store.knownThreadLines(key)
    #expect(known.map(\.author) == ["grok-jarvis", "grok-infra"] && known.map(\.text) == ["How full is /data?", "62%, fine."], "at once, from the step")
    store.openThread(key)
    #expect(store.openBotThread == key)
    await store.loadThread(key)
    let lines = store.knownThreadLines(key)
    #expect(lines.map(\.text) == ["How full is /data?", "62%, fine.", "And /home?", "40%."], "newest at the bottom, header stripped")
    #expect(lines.map(\.author) == ["grok-jarvis", "grok-infra", "grok-jarvis", "grok-infra"])
    #expect(ChatParityServer.requests(host).contains { $0.path == "/api/sessions/swarmhub-from-grok-jarvis/messages" })
}

@Test @MainActor func notConnectedRecipientKeepsTheSendersSteps() async {
    let (store, _, _, host) = threadStore(messages: [["id": 1, "role": "user", "content": "x"]], connected: false)
    await store.loadThread(key)
    #expect(store.knownThreadLines(key).map(\.text) == ["How full is /data?", "62%, fine."])
    #expect(!ChatParityServer.requests(host).contains { $0.path.hasSuffix("/messages") })
    // A recipient SwarmHub does not have at all: nothing to read with, still the steps.
    store.bots.removeAll { $0.hermesProfile == "grok-infra" }
    #expect(store.readableRecipient(key) == nil && store.knownThreadLines(key).count == 2)
    #expect(store.displayName(forProfile: "grok-infra") == "grok-infra")
}

@Test @MainActor func queuedMessagesShowNoReplyLine() {
    let (store, jarvis, _, _) = threadStore()
    jarvis.messages[1].activity!.steps[0].botMessage!.noWait = true
    #expect(store.knownThreadLines(key).map(\.author) == ["grok-jarvis"])
}

// MARK: Arrivals and badge

private func row(_ sender: String, count: Int, active: Double) -> [String: Any] {
    ["id": "swarmhub-from-\(sender)", "title": "From \(sender)", "source": "api_server", "message_count": count, "last_active": active, "preview": "msg \(count)"]
}

@Test func sessionRowsBecomeThreadRows() {
    let thread = HermesBackend.botThreadRow(row("grok-jarvis", count: 2, active: 2_003))
    #expect(thread?.sessionID == "swarmhub-from-grok-jarvis" && thread?.sender == "grok-jarvis" && thread?.updatedAt == Date(timeIntervalSince1970: 2_003))
    #expect(thread?.mark != HermesBackend.botThreadRow(row("grok-jarvis", count: 4, active: 2_103))?.mark)
    #expect(HermesBackend.botThreadRow(["id": "agentapp_chat_1", "title": "From the app"]) == nil, "only bot-msg sessions")
}

@Test @MainActor func newAndChangedThreadsArriveOnceWithABadge() async throws {
    let (store, jarvis, infra, host) = threadStore(rows: [row("grok-jarvis", count: 2, active: 2_003), ["id": "agentapp_x", "title": "Chat"]])
    await store.checkBotMessages(for: infra)
    #expect(infra.messages.isEmpty && !store.hasBotMessageBadge(infra), "the first list only records")
    #expect(ChatParityServer.requests(host).filter { $0.path == "/api/sessions" }.count == 1, "one session-list request")
    #expect(store.botMessages.rows[infra.id]?.map(\.sessionID) == ["swarmhub-from-grok-jarvis"])

    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 4, active: 2_103)))], recipient: infra)
    let line = try #require(infra.messages.last)
    #expect(line.presentation == .botMessage && line.role == .system && line.content == "Jarvis wrote to Infra")
    #expect(line.metadata[BotMessageKey.from] == "grok-jarvis" && line.metadata[BotMessageKey.to] == "grok-infra")
    #expect(store.hasBotMessageBadge(infra) && !store.hasBotMessageBadge(jarvis))
    // The reply landing in the same thread updates the same line.
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 5, active: 2_110)))], recipient: infra)
    #expect(infra.messages.count == 1)
    // Same mark: nothing new.
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 5, active: 2_110)))], recipient: infra)
    #expect(infra.messages.count == 1)
    // A new sender's thread is a new line.
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 5, active: 2_110))),
                              try #require(HermesBackend.botThreadRow(row("coder", count: 2, active: 2_200)))], recipient: infra)
    #expect(infra.messages.count == 2 && infra.messages.last?.content == "coder wrote to Infra")
    #expect(store.botMessages.unread[infra.id] == ["swarmhub-from-grok-jarvis", "swarmhub-from-coder"])
}

@Test @MainActor func aJustSentMessageArrivesEvenOnTheFirstList() throws {
    let (store, _, infra, _) = threadStore()
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 2, active: 2_003))),
                              try #require(HermesBackend.botThreadRow(row("coder", count: 2, active: 1_003)))], recipient: infra, expecting: "grok-jarvis")
    #expect(infra.messages.map(\.content) == ["Jarvis wrote to Infra"], "the expected sender only; the rest is the baseline")
}

@Test @MainActor func aSendersEndedStepChecksTheRecipientAtOnce() async throws {
    let (store, jarvis, infra, host) = threadStore(rows: [row("grok-jarvis", count: 2, active: 2_003)])
    var before = ToolActivity()
    before.apply(ToolEvent(phase: .started, name: "terminal", callID: "c9", command: "bot-msg --from grok-jarvis --to grok-infra -- hi"), at: .now)
    var after = before; after.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c9"), at: .now)
    store.noteEndedBotMessageSteps(before: before, after: after, sender: jarvis)
    try await waitUntil { infra.messages.count == 1 }
    #expect(infra.messages[0].content == "Jarvis wrote to Infra")
    #expect(ChatParityServer.requests(host).filter { $0.path == "/api/sessions" }.count == 1)
    // Still running → no check.
    store.noteEndedBotMessageSteps(before: ToolActivity(), after: before, sender: jarvis)
}

@Test @MainActor func openingTheThreadOrTheChatClearsTheBadge() throws {
    let (store, _, infra, _) = threadStore()
    store.applyBotThreadRows([], recipient: infra)
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("grok-jarvis", count: 2, active: 2_003))),
                              try #require(HermesBackend.botThreadRow(row("coder", count: 2, active: 2_004)))], recipient: infra)
    #expect(store.botMessages.unread[infra.id]?.count == 2)
    store.openThread(key)
    #expect(store.botMessages.unread[infra.id] == ["swarmhub-from-coder"], "that thread's arrival only")
    store.open(infra)
    #expect(!store.hasBotMessageBadge(infra), "the chat shows the lines")
    // While its chat is open, no badge at all.
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("coder", count: 3, active: 2_300)))], recipient: infra)
    #expect(!store.hasBotMessageBadge(infra) && infra.messages.map(\.content) == ["Jarvis wrote to Infra", "coder wrote to Infra"],
            "coder's new message shares its last line")
}

// MARK: Activity and ⌘K

@Test @MainActor func activityListsThreadsNewestFirst() throws {
    let (store, jarvis, infra, _) = threadStore()
    let coder = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder"); store.bots.append(coder)
    #expect(store.infoTabs(for: infra).contains(.activity), "Hermes bots always have the Activity tab")
    store.applyBotThreadRows([try #require(HermesBackend.botThreadRow(row("coder", count: 2, active: 5_000)))], recipient: infra)
    let threads = store.threadSummaries(for: infra)
    #expect(threads.map(\.key) == [BotThreadKey(from: "coder", to: "grok-infra"), key])
    #expect(threads[1].lastLine == "62%, fine." && threads[1].date == Date(timeIntervalSince1970: 2_004))
    #expect(store.threadSummaries(for: jarvis).map(\.key) == [key])
    #expect(store.threadSummaries(for: coder).map(\.key) == [BotThreadKey(from: "coder", to: "grok-infra")])
}

@Test @MainActor func quickSwitcherListsThreads() throws {
    let (store, _, _, _) = threadStore()
    let items = QuickSwitcherModel.items(in: store, query: "")
    let thread = try #require(items.first { $0.title == "Jarvis ↔ Infra" })
    #expect(thread.target == .botThread(key) && !thread.isCommand)
    #expect(items.firstIndex(of: thread)! < items.firstIndex { $0.isCommand }!, "before the commands")
    #expect(QuickSwitcherModel.items(in: store, query: "↔ inf").map(\.title) == ["Jarvis ↔ Infra"])
    #expect(QuickSwitcherModel.items(in: store, query: "Infra").map(\.title).prefix(2) == ["Infra", "Jarvis ↔ Infra"])
}

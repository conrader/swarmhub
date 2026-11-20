import Foundation
import Testing
@testable import AgentApp

/// A server with one agent that waits at a question, as the app reads it: the list of agents and the terminal's screen.
private final class PromptBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var screen = "", state = "blocked"
    private var kind = "permission"
    let agentName: String
    init(agentName: String) { self.agentName = agentName }

    func show(_ text: String) { lock.withLock { screen = text } }
    func statusKind(_ value: String) { lock.withLock { kind = value } }
    func move() { lock.withLock { state = "working" } }

    func session() -> (address: String, session: URLSession) {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        return ("http://\(host)", session)
    }

    private func answer(_ request: URLRequest) -> (Int, Any) {
        lock.withLock { () -> (Int, Any) in
            switch "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")" {
            case "GET /api/workspace":
                let agent: [String: Any] = ["address": "t7", "created_ms": 9, "name": agentName, "state": "live", "template": "tpl-one", "status": ["state": state, "kind": kind], "first_message": NSNull(), "ready": true]
                let template: [String: Any] = ["name": "tpl-one", "description": "", "error": NSNull(), "runtime": ["harness": "Agent One", "provider": NSNull(), "model": NSNull()]]
                return (200, ["core": "c", "version": "1", "agents": [agent], "templates": [template]])
            case "GET /api/agents/t7/9/output": return (200, ["text": screen])
            default: return (404, ["error": "no route"])
            }
        }
    }
}

/// An agent that waits in its terminal is something the person can act on from the chat.
@MainActor struct HerdrPromptTests {
    private final class Notices: @unchecked Sendable { var sent: [(bot: String, text: String)] = [] }

    private func makeStore(_ kind: HerdrServer.Kind = .address, address: String = "http://127.0.0.1:1") -> (store: AppStore, bot: Bot, other: Bot, notices: Notices) {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in TestBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: kind, address: address, sshHost: kind == .ssh ? "studio.example.com" : "", sshUser: kind == .ssh ? "deploy" : ""), token: "t")
        let bot = Bot(name: "Infra", backend: .herdr), other = Bot(name: "Jarvis", backend: .herdr)
        store.bots = [other, bot]; store.selectedBot = other
        let bridge = PromptBridge(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id))
        let served = bridge.session()
        store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: kind, address: served.address), token: "t")
        store.herdrClientSetup = { $0.session = served.session }
        let notices = Notices()
        store.herdrPromptBook.notifier = { bot, text in notices.sent.append((bot.name, text)) }
        return (store, bot, other, notices)
    }

    private let blocked = HerdrTurnStatus.blocked(program: "Agent One")

    @Test func aWaitingAgentIsRaisedOnceAsUnreadAndANotification() async throws {
        let (store, bot, _, notices) = makeStore()
        #expect(store.herdrPrompts[bot.id] == nil && !bot.isUnread && !store.needsAttention(bot))
        store.herdrTurnStatus(blocked, for: bot)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        let prompt = store.herdrPrompts[bot.id]
        #expect(prompt?.program == "Agent One" && prompt?.title == "Agent One is waiting for your answer")
        #expect(bot.isUnread, "the chat is marked unread")
        #expect(store.needsAttention(bot), "and its face wears the attention mark")
        #expect(notices.sent.count == 1 && notices.sent.first?.bot == "Infra" && notices.sent.first?.text == "Agent One is asking a question and waits for your answer.")
        // The server goes on saying that it waits, for hours: nothing is raised again.
        for _ in 0..<5 { store.herdrTurnStatus(blocked, for: bot) }
        #expect(notices.sent.count == 1 && store.herdrPrompts[bot.id]?.since == prompt?.since)
        // The person reads the chat (the mark goes) while the agent still waits: it is not marked again.
        store.open(bot)
        #expect(!bot.isUnread)
        store.herdrTurnStatus(blocked, for: bot)
        #expect(!bot.isUnread && notices.sent.count == 1)
    }

    @Test func thePromptGoesWhenTheAgentMovesAndANewOneIsRaisedAnew() async throws {
        let (store, bot, other, notices) = makeStore()
        store.herdrTurnStatus(blocked, for: bot)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        store.herdrTurnStatus(.working(program: "Agent One"), for: bot)
        #expect(store.herdrPrompts[bot.id] == nil && !store.needsAttention(bot))
        store.herdrTurnStatus(blocked, for: bot)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(store.herdrPrompts[bot.id] != nil && notices.sent.count == 2, "a second question is a new thing to tell")
        // The turn ends (the person stopped it, or it finished): no prompt is left behind.
        store.herdrTurnStatus(nil, for: bot)
        #expect(store.herdrPrompts[bot.id] == nil)
        #expect(store.herdrPrompts[other.id] == nil && notices.sent.allSatisfy { $0.bot == "Infra" }, "only the bot that waits")
    }

    @Test func aMutedBotIsMarkedButSendsNoNotification() async throws {
        let (store, bot, _, notices) = makeStore()
        bot.notificationsEnabled = false
        store.herdrTurnStatus(blocked, for: bot)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(store.herdrPrompts[bot.id] != nil && bot.isUnread)
        #expect(notices.sent.isEmpty, "the bot's notification switch is respected")
    }

    @Test func anAgentThatWaitsBeforeAnyMessageIsRaisedToo() async throws {
        let (store, bot, _, notices) = makeStore()
        // The chat header's reading of the server's list: the agent shows a prompt, and no turn runs.
        store.herdrReadiness[bot.id] = .blocked(program: "Agent One")
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(store.herdrPrompts[bot.id]?.program == "Agent One" && notices.sent.count == 1)
        store.herdrReadiness[bot.id] = .ready
        #expect(store.herdrPrompts[bot.id] == nil)
        store.herdrReadiness[bot.id] = .starting(program: "Agent One")
        #expect(store.herdrPrompts[bot.id] == nil && notices.sent.count == 1)
    }

    @Test func aTurnThatReportsAWaitingAgentRaisesItAndItsEndClearsIt() async throws {
        let (store, bot, _, notices) = makeStore()
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true, turnState: .incomplete)
        bot.messages = [ChatMessage(role: .user, content: "hi"), reply]
        let (stream, feed) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let consuming = Task { try await store.consumeTurn(stream, assistant: reply, bot: bot) }
        feed.yield(.status(HerdrTurnStatus.working(program: "Agent One").code)); feed.yield(.status(blocked.code))
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(reply.metadata[TurnKey.agent] == blocked.code && notices.sent.count == 1)
        feed.yield(.completed); feed.finish()
        let end = try await consuming.value
        store.finishTurn(end, assistant: reply, bot: bot, in: bot)
        #expect(store.herdrPrompts[bot.id] == nil && reply.metadata[TurnKey.agent] == nil)
    }

    @Test func theChatShowsWhatTheTerminalAsks() async throws {
        let (store, bot, _, _) = makeStore()
        let bridge = PromptBridge(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id))
        let served = bridge.session()
        store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
        store.herdrClientSetup = { made in made.session = served.session }
        bridge.show("""
            ╭──────────────────────────────────────────────╮
            │ Would you like to run the following command? │
            ╰──────────────────────────────────────────────╯

              $ make publish

            › 1. Yes, proceed (y)
              2. No, and tell the agent what to do differently (esc)
            """)
        store.herdrTurnStatus(.blocked(program: nil), for: bot)
        #expect(store.herdrPrompts[bot.id] == nil && store.herdrPromptAnswer(for: bot) == nil)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        let prompt = try #require(store.herdrPrompts[bot.id])
        #expect(prompt.question == "Would you like to run the following command?\n$ make publish\n› 1. Yes, proceed (y)\n2. No, and tell the agent what to do differently (esc)")
        #expect(prompt.agent == HerdrClient.AgentRef(address: "t7", createdMs: 9))
        #expect(prompt.program == "Agent One", "the server's name for the agent program, when the turn gave none")
        #expect(store.herdrPromptAnswer(for: bot) == .browser(URL(string: served.address)!))
        // A second question on the same screen replaces the first.
        bridge.show("Allow reading /etc/hosts?\n› Yes\n  No")
        await store.refreshHerdrPrompt(for: bot)
        #expect(store.herdrPrompts[bot.id]?.question == "Allow reading /etc/hosts?\n› Yes\nNo")
        // A screen that cannot be read leaves what was read.
        bridge.show("")
        await store.refreshHerdrPrompt(for: bot)
        #expect(store.herdrPrompts[bot.id]?.question == "Allow reading /etc/hosts?\n› Yes\nNo")
    }

    @Test func theButtonOpensTheAgentsOwnTerminalWhereverItsServerIs() throws {
        func script(_ address: String) -> String { "attach \(address)" }
        let mac = HerdrServer(id: "a", name: "This Mac", kind: .local, address: HerdrServer.loopback(port: 8787))
        #expect(HerdrPromptAnswer.plan(server: mac, address: "t7", name: "Infra", localScript: script, sshOptions: nil) == .terminal(script: "attach t7"))
        let box = HerdrServer(id: "b", name: "Studio", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "studio.example.com", sshUser: "deploy")
        let options = try #require(HerdrTunnel.options(for: box, home: "/Users/you"))
        guard case .terminal(let remote)? = HerdrPromptAnswer.plan(server: box, address: "t7", name: "Infra", localScript: script, sshOptions: options) else { Issue.record("no terminal for a server over SSH"); return }
        #expect(remote.hasPrefix("#!/bin/sh\n") && remote.contains("exec '/usr/bin/ssh' '-t' "))
        #expect(remote.contains("'-l' 'deploy'") && remote.contains("'--' 'studio.example.com' "))
        #expect(remote.contains("exec \"$c\" attach t7") && remote.contains("exec hc attach t7"), "Herdr Core's own viewer, on the server")
        let typed = HerdrServer(id: "c", name: "Other", kind: .address, address: "http://10.0.0.5:8787")
        #expect(HerdrPromptAnswer.plan(server: typed, address: "t7", name: "Infra", localScript: script, sshOptions: nil) == .browser(URL(string: "http://10.0.0.5:8787")!))
        #expect(HerdrPromptAnswer.terminal(script: "").button == "Answer in Terminal" && HerdrPromptAnswer.browser(URL(string: "http://x")!).button == "Open in Browser")
        // An address that is not a terminal's name never reaches a command line.
        for bad in ["", "t7; rm -rf ~", "-oProxyCommand=x", "t7 t8", "$(id)", "t7'"] {
            #expect(!HerdrPromptAnswer.isSafe(address: bad))
            #expect(HerdrPromptAnswer.plan(server: mac, address: bad, name: "Infra", localScript: script, sshOptions: nil) == nil)
            #expect(HerdrPromptAnswer.plan(server: box, address: bad, name: "Infra", localScript: script, sshOptions: options) == nil)
        }
        #expect(HerdrPromptAnswer.isSafe(address: "t7") && HerdrPromptAnswer.isSafe(address: "build-box/t12"))
    }

    @Test func aClaudeWelcomeScreenNeverMarksTheBotUnreadOrNotifies() async throws {
        let (store, bot, _, notices) = makeStore()
        let bridge = PromptBridge(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id))
        bridge.statusKind("ready")
        bridge.show("Claude Code v2\nWelcome back!\n❯ Try fixing a bug\n? for shortcuts")
        let served = bridge.session()
        store.saveHerdrServer(.init(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "fixture")
        store.herdrClientSetup = { $0.session = served.session }
        store.herdrTurnStatus(.blocked(program: "Claude"), for: bot)
        await store.refreshHerdrPrompt(for: bot)
        #expect(store.herdrPrompts[bot.id] == nil && !bot.isUnread && notices.sent.isEmpty)
        bridge.show("Do you trust the files in this folder?\n1. Yes, I trust this folder\n2. No, exit")
        await store.refreshHerdrPrompt(for: bot)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(bot.isUnread && notices.sent.count == 1)
    }

    @Test func aRemovedBotLeavesNoPrompt() async throws {
        let (store, bot, _, _) = makeStore()
        store.herdrReadiness[bot.id] = .blocked(program: nil)
        try await waitUntil { store.herdrPrompts[bot.id] != nil }
        #expect(store.herdrPrompts[bot.id] != nil)
        store.bots.removeAll { $0.id == bot.id }
        store.herdrReadiness[bot.id] = nil
        #expect(store.herdrPrompts[bot.id] == nil)
    }
}

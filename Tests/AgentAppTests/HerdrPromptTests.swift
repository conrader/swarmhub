import Foundation
import Testing
@testable import AgentApp

/// A server with one agent that waits at a question, as the app reads it: the list of agents and the terminal's screen.
private final class PromptBridge: @unchecked Sendable {
    private let lock = NSLock()
    let workspaceReads = AwaitableLog<String>()
    private var screen = "", state = "blocked"
    private var kind = "permission"
    let agentName: String
    init(agentName: String) { self.agentName = agentName }

    func show(_ text: String) { lock.withLock { screen = text } }
    func statusKind(_ value: String) { lock.withLock { kind = value } }
    func ready() { lock.withLock { state = "idle" } }
    func move() { lock.withLock { state = "working" } }

    func session() -> (address: String, session: URLSession) {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        return ("http://\(host)", session)
    }

    private func answer(_ request: URLRequest) -> (Int, Any) {
        lock.withLock { () -> (Int, Any) in
            switch "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")" {
            case "GET /api/workspace":
                workspaceReads.append(state)
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
    private final class Notices: @unchecked Sendable { var sent: [(bot: String, group: String?, text: String)] = [] }

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
        store.herdrPromptBook.notifier = { bot, group, text in notices.sent.append((bot.name, group?.name, text)) }
        return (store, bot, other, notices)
    }

    private let blocked = HerdrTurnStatus.blocked(program: "Agent One")

    @Test(arguments: [false, true])
    func promptRetainsBothMessagesInOrderThroughReopen(retryFirst: Bool) async throws {
        let source = temporaryStore(), first = ScriptedTurnBackend(steerless: true)
        let (original, bot) = steerStore(first, url: source)
        let bridge = PromptBridge(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id))
        let served = bridge.session()
        original.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
        original.herdrClientSetup = { $0.session = served.session }
        let older = ChatMessage(role: .assistant, content: "Older partial answer", turnState: .incomplete)
        bot.messages.append(older)
        #expect(original.send(text: "First"))
        try await first.calls.wait { $0.contains("send:First") }
        #expect(original.send(text: "Second"))
        await first.fail(HerdrClient.Failure.waitingAtPrompt)
        try await waitUntil { !original.anyTurnRunning }
        #expect(original.turns.nextMessages.map(\.bubble.content) == ["First", "Second"])
        #expect(bot.messages.filter { $0.role == .assistant }.map(\.id) == [older.id])
        original.turns.nextMessages = []
        let next = ScriptedTurnBackend(), keys = InMemoryKeyStore()
        func reopen() -> AppStore {
            let store = AppStore(storeURL: source, autoStart: false, backendFactory: { _ in next }, keyStore: keys, defaults: isolatedDefaults())
            store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
            store.herdrClientSetup = { $0.session = served.session }
            return store
        }
        var restored = reopen()
        restored.resumeRestoredNextMessages()
        try await bridge.workspaceReads.wait { $0.contains("blocked") }
        #expect(next.calls.all.isEmpty && restored.turns.nextMessages.count == 2)
        bridge.ready()
        try await next.calls.wait { $0.contains("send:First") }
        restored.resumeRestoredNextMessages()
        restored.sendQueuedNextMessage()
        if retryFirst {
            // A ready terminal says nothing about the outcome of the send it just accepted.
            await next.fail(HerdrClient.Failure.unconfirmedDelivery)
            try await waitUntil { !restored.anyTurnRunning }
            restored = reopen()
            restored.resumeRestoredNextMessages()
            #expect(!restored.anyTurnRunning && next.calls.all == ["send:First"])
            let row = try #require(restored.bots[0].messages.first { $0.turnState == .notSent })
            restored.retry(row, sendAnyway: true)
            try await next.calls.wait { $0 == ["send:First", "send:First"] }
        }
        await next.emit(.token("One"), .completed); await next.end()
        try await next.calls.wait { $0.contains("send:Second") }
        await next.emit(.token("Two"), .completed); await next.end()
        try await waitUntil { !restored.anyTurnRunning }
        let expected = retryFirst ? ["send:First", "send:First", "send:Second"] : ["send:First", "send:Second"]
        #expect(next.calls.all == expected)
        #expect(restored.bots[0].messages.filter { $0.role == .user }.map(\.content) == ["First", "Second"])
        let again = reopen()
        again.resumeRestoredNextMessages()
        #expect(!again.anyTurnRunning && !again.hasWaitingTurn(in: again.bots[0]))
        #expect(next.calls.all == expected)
    }

    @Test func promptReadyAfterQueuedSendIsCancelledDoesNotDispatch() async throws {
        let backend = ScriptedTurnBackend(steerless: true), (store, bot) = steerStore(backend)
        let bridge = PromptBridge(agentName: HerdrBackend.agentName(botName: bot.name, botID: bot.id))
        let served = bridge.session()
        store.saveHerdrServer(.init(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
        store.herdrClientSetup = { $0.session = served.session }
        #expect(store.send(text: "First"))
        try await backend.calls.wait { $0 == ["send:First"] }
        #expect(store.send(text: "Second"))
        await backend.fail(HerdrClient.Failure.waitingAtPrompt)
        try await waitUntil { store.isIdle(bot) && !store.turns.checkingPromptQueues.isEmpty }
        let first = try #require(bot.messages.first { $0.content == "First" })
        let claim = try #require(store.waitingDirectClaim(for: first))
        #expect(store.cancelQueuedSend(claim))
        bridge.ready()
        try await waitUntil { store.turns.checkingPromptQueues.isEmpty }
        #expect(!store.hasWaitingTurn(in: bot) && store.isIdle(bot))
        #expect(backend.calls.all == ["send:First"])
    }

    @Test func refusedSignInAppearsInItsChatWhileTheMessageCanBeRetried() {
        let (store, bot, peer, _) = makeStore()
        let group = GroupChat(name: "Review", memberIDs: [bot.id, peer.id])
        store.groups = [group]
        let ref = HerdrClient.AgentRef(address: "t9", createdMs: 20)
        let failure = HerdrClient.Failure.signInRequired(ref, "Gemini")
        let row = ChatMessage(role: .assistant, content: "")
        group.messages.append(row)
        store.finishTurn(.error(failure), assistant: row, bot: bot, in: group)
        #expect(row.turnState == .notSent && row.metadata[TurnKey.why] == "sign-in required" && store.errorMessage == nil)
        #expect(store.herdrPrompt(for: bot, in: group)?.agent == ref)
        #expect(store.herdrPrompt(for: peer, in: group) == nil && store.herdrPrompt(for: bot, in: nil) == nil)
        store.forgetHerdrAgentState(for: bot)
        #expect(store.herdrPrompt(for: bot, in: group) == nil)

        let direct = ChatMessage(role: .assistant, content: "")
        bot.messages.append(direct)
        store.finishTurn(.error(failure), assistant: direct, bot: bot, in: bot)
        #expect(store.herdrPrompt(for: bot, in: nil)?.actionTitle == "Sign in here")
        #expect(direct.turnState == .notSent && store.errorMessage == nil)
    }

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

    @Test(arguments: ["permission", "trust"])
    func aGroupTurnRaisesItsOwnTerminalPromptAndClearsItOnEnd(kind: String) async throws {
        let (store, bot, _, notices) = makeStore()
        let group = GroupChat(name: "Review", memberIDs: [bot.id])
        store.groups = [group]
        let name = try #require(HerdrBackend.groupRuntimeName(sessionID: store.turnSessionID(in: group, bot: bot), botID: bot.id))
        let bridge = PromptBridge(agentName: name)
        bridge.statusKind(kind)
        bridge.show(kind == "trust" ? "Do you trust this folder?" : "Would you like to run the following command?")
        let served = bridge.session()
        store.herdrClientSetup = { $0.session = served.session }
        store.saveHerdrServer(.init(id: HerdrServer.defaultID, name: "Studio", kind: .address, address: served.address), token: "t")
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true, authorID: bot.id)
        let (stream, feed) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        defer { feed.finish() }
        let consuming = Task { try await store.consumeTurn(stream, assistant: reply, bot: bot, group: group) }
        feed.yield(.status(blocked.code))
        try await waitUntil { store.herdrPrompts[group.id] != nil }
        #expect(store.herdrPrompts[group.id]?.agent == .init(address: "t7", createdMs: 9))
        #expect(group.isUnread && store.herdrPrompts[bot.id] == nil && !bot.isUnread)
        #expect(notices.sent.count == 1 && notices.sent.first?.group == group.name)
        #expect(store.herdrPromptAnswer(for: bot, in: group) == .browser(URL(string: served.address)!))
        feed.yield(.status(blocked.code)); feed.yield(.completed); feed.finish()
        store.finishTurn(try await consuming.value, assistant: reply, bot: bot, in: group)
        #expect(store.herdrPrompts[group.id] == nil && notices.sent.count == 1)
    }

    @Test func concurrentGroupTurnsKeepTheirOwnPermissionPrompts() {
        let (store, primary, other, _) = makeStore()
        store.herdrClientSetup = nil
        let group = GroupChat(name: "Review", memberIDs: [primary.id, other.id])
        store.groups = [group]
        store.beginTurn(in: group, bot: primary, assistant: nil)
        let second = ConversationTurn(conversation: group, botID: other.id, assistant: nil, groupRun: nil)
        store.runningTurns[second.token] = second
        for (bot, address) in [(primary, "t1"), (other, "t2")] {
            store.herdrTurnStatus(blocked, for: bot, in: group)
            let id = store.herdrPromptID(for: bot, in: group)
            store.herdrPrompts[id] = HerdrPrompt(program: bot.name, question: "Allow fixture?",
                                                  agent: .init(address: address, createdMs: 1), since: Date())
        }
        #expect(store.herdrPrompt(for: primary, in: group)?.agent?.address == "t1")
        #expect(store.herdrPrompt(for: other, in: group)?.agent?.address == "t2")
        store.herdrTurnStatus(nil, for: primary, in: group)
        #expect(store.herdrPrompt(for: primary, in: group) == nil)
        #expect(store.herdrPrompt(for: other, in: group)?.agent?.address == "t2")
        group.memberIDs.removeAll { $0 == other.id }
        #expect(store.herdrPromptAnswer(for: other, in: group) == nil)
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

@MainActor @Test func boppyShowsTheInterBotLaunchOnItsPromptWhileAstraIsPending() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Boppy", backend: .herdr)
    let id = bot.id.uuidString.lowercased(), name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    let requests = AwaitableLog<String>()
    let http = MockHTTPProtocol.serve { req in
        let path = req.url?.path ?? ""
        requests.append("\(req.httpMethod ?? "") \(path)")
        switch path {
        case "/api/workspace":
            let agent: [String: Any] = ["name":name, "address":"fixture", "created_ms":9, "state":"live", "template":"runner",
                                        "status":["state":"blocked", "kind":"permission"]]
            let template: [String: Any] = ["name":"runner", "runtime":["harness":"Gemini"], "model_agent":"fixture",
                                           "models":[["id":"astra", "label":"Astra"]]]
            return (200, ["core":"fixture-core", "agents":[agent], "templates":[template]])
        case "/api/profiles":
            let launch: [String: Any] = ["core":"fixture-core", "address":"fixture", "created_ms":9,
                                         "runtime":["harness":"Gemini", "model":"Gemini Neon", "model_id":"neon"]]
            return (200, [["id":1, "runtime_name":name, "sessions":[launch]]])
        case "/api/agents/fixture/9/output":
            return (200, ["text":"Would you like to run the following command?\nSSH directory listing (fixture)\n1. Allow once\n2. Deny"])
        case "/api/bots": return (200, ["bots":[]])
        case "/api/bots/history":
            let item: [String: Any] = ["id":1,"bot":id,"kind":"message","text":"Doc sent Boppy the archive question.",
                                       "at_ms":1000,"unread":true,"notify":false]
            return (200, ["items":[item],"more":false])
        case "/api/approvals":
            return (200, ["pending":[["id":7,"agent":name,"provider":"Gemini","tool":"SSH fixture","cwd":"/fixture",
                                      "arguments":"archive","core":"fixture-core","address":"fixture","created_ms":9,"launch_model":"Gemini Neon"]]])
        default: return (404, [:])
        }
    }
    let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
    store.saveHerdrServer(server, token: "fixture")
    store.herdrClientSetup = { $0.session = http.session }
    store.bots = [bot]
    store.setHerdrModel("astra", for: bot)
    await store.syncTeam(server)
    #expect(bot.messages.contains { $0.content == "Doc sent Boppy the archive question." })
    let reading = try #require(await store.refreshHerdrAgentReading(for: bot, requireFresh: true))
    #expect(reading.short == "Gemini Neon" && reading.pendingLine?.contains("next new direct turn") == true)
    #expect(reading.model?.id == "astra")
    store.herdrTurnStatus(.blocked(program: "Gemini"), for: bot)
    try await waitUntil { store.herdrPrompts[bot.id]?.origin?.contains("Gemini Neon · fixture/9") == true }
    let reviews = try await store.herdrClient(for: server).approvals(for: name)
    #expect(reviews.map(\.launchModel) == ["Gemini Neon"])
    #expect(store.modelSwitchPending(bot))
    #expect(requests.all.allSatisfy { !$0.hasPrefix("POST /api/agents/") && !$0.hasPrefix("POST /api/approvals") })
}

@MainActor @Test func activityMatchesApprovalsToTheCurrentServerChatAndSession() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Build", backend: .herdr)
    let group = GroupChat(name: "Release", memberIDs: [bot.id])
    store.bots = [bot]; store.groups = [group]
    let direct = try #require(store.approvalAgentNames(for: bot, in: nil).first)
    let shared = try #require(store.approvalAgentNames(for: bot, in: group).first)
    let requests = AwaitableLog<String>()
    let http = MockHTTPProtocol.serve { request in
        let path = request.url?.path ?? ""
        requests.append(path)
        switch path {
        case "/api/approvals":
            let rows: [[String: Any]] = [(direct, 1, 8), (shared, 2, 9), (shared, 3, 7)].map { name, id, created in
                ["id": id, "agent": name, "provider": "Codex", "tool": "Shell", "arguments": "run",
                 "cwd": "/fixture", "core": "core", "address": name, "created_ms": created]
            }
            return (200, ["pending": rows])
        case "/api/workspace":
            let agents: [[String: Any]] = [(direct, 8), (shared, 9)].map { name, created in
                ["name": name, "address": name, "created_ms": created, "state": "live"]
            }
            return (200, ["agents": agents, "core": "core", "templates": []])
        default: return (404, [:])
        }
    }
    let server = HerdrServer(id: HerdrServer.defaultID, name: "Fixture", kind: .address, address: "http://\(http.host)")
    store.saveHerdrServer(server, token: "fixture")
    store.herdrClientSetup = { $0.session = http.session }
    let pending = try await store.herdrClient(for: server).approvals(for: [direct, shared])
    let inboxes = [server.id: WorkspaceApprovalInbox(server: server, requests: pending, unavailable: false)]
    #expect(requests.all == ["/api/approvals", "/api/workspace"])
    #expect(store.approvals(for: bot, in: nil, inboxes: inboxes).map(\.id) == [1])
    #expect(store.approvals(for: bot, in: group, inboxes: inboxes).map(\.id) == [2])
    #expect(store.workspaceActivity(inboxes: inboxes).filter { $0.section == .attention }.map(\.id) == [bot.id, group.id])
    var moved = server
    moved.address = "http://127.0.0.1:4567"
    store.saveHerdrServer(moved, token: "changed")
    #expect(store.approvals(for: bot, in: group, inboxes: inboxes).isEmpty)
}

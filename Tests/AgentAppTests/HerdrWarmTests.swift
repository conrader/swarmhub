import Foundation
import Testing
@testable import AgentApp

// A Herdr bot's agent is started ahead of its first message, and the chat says what a turn is waiting for.

/// A bridge with one agent at most, as the app sees it: the workspace's list, a launch with a task or ahead of one
/// (`warm`), the agent's saved rows, and messages to it. A message is answered at once with "ok"; one that reaches an
/// agent that is not ready yet is kept (`pending`) and typed, and answered, when the agent is ready.
private final class WarmBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var agent: [String: Any]?, rows: [[String: Any]] = [], launchBodies: [[String: Any]] = [], sent: [String] = []
    private var held = false, arrived = 0, ends = 0, notReadyReads = 0, older = false, givesUp = false

    var launches: [[String: Any]] { lock.withLock { launchBodies } }
    var texts: [String] { lock.withLock { sent } }
    /// Launch requests that reached the bridge, answered or not.
    var launchRequests: Int { lock.withLock { arrived } }
    var ended: Int { lock.withLock { ends } }

    /// A bridge from before agents could be started ahead of a task: it does not know `warm`.
    func beOlder() { lock.withLock { older = true } }
    /// A launch that is not answered until `release`.
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }
    /// An agent started ahead of time stays not ready for this many reads of the workspace.
    func startSlowly(reads: Int) { lock.withLock { notReadyReads = reads } }
    /// The agent never becomes ready: what was kept for it is given up when it would have been typed.
    func neverReady() { lock.withLock { givesUp = true } }
    /// What was typed so far was never typed after all.
    func forgetDelivery() { lock.withLock { agent?["warm"] = true; rows = rows.map { row in row["kind"] as? String == "task" ? row.merging(["state": "not_sent"]) { _, new in new } : row } } }

    func client() -> HerdrClient {
        let (host, session) = MockHTTPProtocol.serve { [self] in answer($0) }
        var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
        client.following = .polling; client.pollInterval = .milliseconds(5); client.agentCheckInterval = .milliseconds(10)
        return client
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func row(_ kind: String, _ text: String) -> [String: Any] { ["id": rows.count + 1, "kind": kind, "state": kind == "task" ? "sent" : "received", "text": text] }

    func answer(_ request: URLRequest) -> (Int, Any) {
        let body = Self.body(request)
        switch "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")" {
        case "GET /api/workspace":
            return lock.withLock { () -> (Int, Any) in
                if notReadyReads > 0 {
                    notReadyReads -= 1
                    if notReadyReads == 0, givesUp {
                        rows = rows.map { row in row["state"] as? String == "pending" ? row.merging(["state": "not_sent", "detail": "it did not report in time"]) { _, new in new } : row }
                    } else if notReadyReads == 0 {
                        agent?["ready"] = true
                        // What was kept is typed now, and answered.
                        if rows.contains(where: { $0["state"] as? String == "pending" }) {
                            rows = rows.map { row in row["state"] as? String == "pending" ? row.merging(["state": "sent"]) { _, new in new } : row }
                            rows.append(row("reply", "ok")); agent?["warm"] = false
                        }
                    }
                }
                let template: [String: Any] = ["name": "tpl-one", "description": "", "error": NSNull(), "runtime": ["harness": "Agent One", "provider": NSNull(), "model": NSNull()]]
                return (200, ["core": "c", "version": "1", "agents": agent.map { [$0] } ?? [], "templates": [template]])
            }
        case "GET /api/profiles": return (200, [Any]())
        case "POST /api/agents":
            lock.withLock { arrived += 1 }
            while lock.withLock({ held }) { Thread.sleep(forTimeInterval: 0.002) }
            return lock.withLock { () -> (Int, Any) in
                let warm = body["warm"] as? Bool == true
                if warm, older { return (422, ["error": "unknown field `warm`"]) }
                launchBodies.append(body)
                agent = ["address": "t1", "created_ms": 5, "name": body["name"] ?? "", "state": "live", "template": body["template"] ?? "", "status": NSNull(), "first_message": NSNull()]
                if !older { agent?["ready"] = !warm || notReadyReads == 0; agent?["warm"] = warm }
                if let task = body["task"] as? String { rows.append(row("task", task)); rows.append(row("reply", "ok")) }
                return (201, agent ?? [:])
            }
        case "GET /api/history/c/t1/5": return (200, ["items": lock.withLock { rows }])
        case "GET /api/history/c/t1/5/draft": return (200, ["draft": NSNull(), "tools": [Any]()])
        case "POST /api/agents/t1/5/messages":
            return lock.withLock { () -> (Int, Any) in
                let text = body["text"] as? String ?? ""
                sent.append(text)
                if agent?["ready"] as? Bool == false {
                    rows.append(row("task", text).merging(["state": "pending"]) { _, new in new })
                    return (202, ["status": NSNull(), "started": NSNull(), "queued": true])
                }
                rows.append(row("task", text)); rows.append(row("reply", "ok")); agent?["warm"] = false
                return (200, ["status": "sent"])
            }
        case "POST /api/agents/t1/5/end": return lock.withLock { () -> (Int, Any) in ends += 1; agent = nil; rows = []; return (200, [String: Any]()) }
        default: return (404, ["error": "no route"])
        }
    }
}

/// A store whose one Herdr server is `bridge`, with one bot on it.
@MainActor private func warmStore(_ bridge: WarmBridge) -> (store: AppStore, bot: Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let client = bridge.client()
    store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Test", kind: .address, address: client.baseURL.absoluteString), token: "t")
    store.herdrClientSetup = { made in
        made.session = client.session; made.following = .polling; made.pollInterval = client.pollInterval; made.agentCheckInterval = client.agentCheckInterval
    }
    let bot = Bot(name: "Ada", backend: .herdr)
    store.bots = [bot]
    return (store, bot)
}

/// What a turn is waiting for travels as a code and is said in plain words, where "Thinking…" used to stand for all of it.
@Test func theChatSaysWhatATurnIsWaitingFor() {
    let all: [HerdrTurnStatus] = [.sending, .starting(program: "Agent One"), .starting(program: nil), .delivered(program: "Agent One"), .working(program: "Agent One"),
                                  .blocked(program: "Agent One"), .finishing, .failing(program: nil)]
    for status in all { #expect(HerdrTurnStatus(code: status.code) == status, "\(status.code)") }
    #expect(HerdrTurnStatus(code: "Planning") == nil && HerdrTurnStatus(code: "herdr.unknown") == nil && HerdrTurnStatus.starting(program: "Agent One").code == "herdr.starting|Agent One")
    #expect(all.map(\.line) == ["Sending…", "Starting Agent One…", "Starting the agent…", "Delivered to Agent One…", "Agent One is working…",
                                "Agent One is waiting for you in its terminal", "Finishing…", "The agent reported an error"])
    #expect(HerdrTurnStatus.starting(program: nil).note == "the first reply takes longer" && HerdrTurnStatus.working(program: nil).note == nil)

    // What the agent reports, read for the turn it is in.
    func of(_ state: String, began: Bool = false, starting: Bool = false) -> HerdrTurnStatus { .of(agentState: state, program: "Agent One", began: began, starting: starting) }
    #expect(of("working") == .working(program: "Agent One") && of("blocked") == .blocked(program: "Agent One") && of("error") == .failing(program: "Agent One"))
    #expect(of("idle") == .delivered(program: "Agent One") && of("done", began: true) == .finishing, "an agent that is idle before it began has not taken the message yet")
    #expect(of("", starting: true) == .starting(program: "Agent One") && of("idle", starting: true) == .starting(program: "Agent One") && of("unknown", began: true) == .working(program: "Agent One"))

    // The live line under a reply.
    let start = Date(timeIntervalSinceReferenceDate: 1_000), now = start + 14
    #expect(ActivityCopy.liveLine(nil, since: start, now: now) == "Thinking… · 14 s", "a turn with no report reads as before")
    #expect(ActivityCopy.liveLine(nil, since: start, now: now, status: .starting(program: "Agent One")) == "Starting Agent One… · the first reply takes longer · 14 s")
    #expect(ActivityCopy.liveLine(nil, since: start, now: now, status: .working(program: "Agent One")) == "Agent One is working… · 14 s")
    var activity = ToolActivity(); activity.apply(ToolEvent(phase: .started, name: "bash", preview: "ls", callID: "1"), at: start + 2)
    #expect(ActivityCopy.liveLine(activity, since: start, now: now, status: .working(program: "Agent One")) == "Working… · Running a command · step 1 · 14 s", "a running tool step says more than the report")
    #expect(ActivityCopy.liveLine(activity, since: start, now: now, status: .blocked(program: "Agent One")) == "Agent One is waiting for you in its terminal · 1 step · 14 s", "unless the agent waits for the person")
    activity.apply(ToolEvent(phase: .completed, name: "bash", callID: "1"), at: start + 3)
    #expect(ActivityCopy.liveLine(activity, since: start, now: now, status: .working(program: "Agent One")) == "Agent One is working… · 1 step · 14 s")
    #expect(ActivityCopy.liveLine(activity, since: start, lastText: now - 1, now: now, status: .working(program: "Agent One")) == "Typing… · 1 step · 14 s", "text that arrives says more too")
    #expect(ActivityCopy.sidebarLine(nil, lastText: nil, now: now, status: .starting(program: "Agent One")) == "Starting Agent One…" && ActivityCopy.sidebarLine(nil, lastText: nil, now: now) == "Thinking…")
}

/// The follower says "starting" for a turn that started the agent until the agent shows work, and "delivered" for a
/// message to a running agent that has not taken it up yet.
@Test func aTurnThatStartedItsAgentSaysSoUntilTheAgentWorks() throws {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    func agent(_ status: String) throws -> HerdrClient.Agent { try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t1","created_ms":5,"name":"x","state":"live","template":"one","status":\#(status)}"#.utf8)) }
    let clock = ContinuousClock().now
    var launched = HerdrTurnFollower(after: 0, program: "Agent One", starting: true)
    launched.take(agent: try agent("null")); _ = launched.judgeAgent(now: clock)
    launched.take(agent: try agent(#"{"state":"idle"}"#)); _ = launched.judgeAgent(now: clock)
    launched.take(agent: try agent(#"{"state":"working"}"#)); _ = launched.judgeAgent(now: clock)
    launched.take(agent: try agent(#"{"state":"done"}"#)); _ = launched.judgeAgent(now: clock)
    #expect(launched.drain() == [.status(.starting(program: "Agent One")), .status(.working(program: "Agent One")), .status(.finishing)])
    var running = HerdrTurnFollower(after: 3, program: "Agent One")
    running.take(agent: try agent(#"{"state":"done"}"#)); _ = running.judgeAgent(now: clock)
    running.take(tools: [.init(seq: 1, tool: "Bash", detail: nil, finished: false, failed: false)])
    running.take(agent: try agent(#"{"state":"blocked"}"#)); _ = running.judgeAgent(now: clock)
    #expect(running.drain() == [.status(.delivered(program: "Agent One")), .tool(.init(seq: 1, tool: "Bash", detail: nil, finished: false, failed: false), isNew: true), .status(.blocked(program: "Agent One"))])
    // A message the bridge still keeps for a starting agent: what the program reports meanwhile is its start-up.
    var kept = HerdrTurnFollower(after: 0, program: "Agent One", starting: true)
    kept.take(rows: [.init(id: 1, kind: "task", text: "hi", state: "pending")])
    for state in ["working", "done"] { kept.take(agent: try agent(#"{"state":"\#(state)"}"#)); _ = kept.judgeAgent(now: clock) }
    #expect(kept.judgeAgent(now: clock + .seconds(600)) == .waiting && kept.drain() == [.status(.starting(program: "Agent One"))], "no \"working\", no \"finishing\", and no giving up while the bridge waits")
    kept.take(rows: [.init(id: 1, kind: "task", text: "hi", state: "sent")]); kept.take(agent: try agent(#"{"state":"working"}"#)); _ = kept.judgeAgent(now: clock)
    #expect(kept.drain() == [.status(.working(program: "Agent One"))])
}

/// A start ahead of time is a launch with no task and nothing else changed; a bot that has an agent gets no second
/// one; and the first message to such an agent carries what a first task carries, once.
@Test func anAgentIsStartedAheadOfItsFirstMessageAndReadsItsInstructionsOnce() async throws {
    let bridge = WarmBridge(), client = bridge.client()
    let shop = HerdrBotProject(id: 1, name: "shop", machine: "box")
    let started = try await client.warm(name: "ada-abc123", template: nil, projects: [shop])
    guard case .started(let agent, let program) = started else { Issue.record("no agent was running, so one is started"); return }
    #expect(program == "Agent One" && agent.warm == true && agent.ready == true && !agent.isStarting)
    let launch = try #require(bridge.launches.first)
    #expect(bridge.launches.count == 1 && launch["warm"] as? Bool == true && launch["task"] == nil && launch["name"] as? String == "ada-abc123" && launch["template"] as? String == "tpl-one" && launch["projects"] as? [Int] == [1])
    let again = try await client.warm(name: "ada-abc123", template: nil, projects: [shop])
    guard case .running(let same, _) = again else { Issue.record("the running agent is found"); return }
    #expect(same.ref == agent.ref && bridge.launches.count == 1, "never a second agent")

    let instructions = "Be brief.\n\n" + HerdrBotMessage.note, once = [(marker: HerdrBotMessage.marker, note: HerdrBotMessage.note)]
    let heard = LockedTrace()
    let first = try await client.deliver("hi", name: "ada-abc123", template: nil, instructions: instructions, once: once, status: { heard.add($0.code) })
    #expect(!first.launched && first.program == "Agent One" && first.after == 0 && bridge.launches.count == 1 && heard.read().isEmpty, "the message finds the agent running and ready")
    #expect(bridge.texts == [HerdrClient.firstTask("hi", instructions: instructions)] && bridge.texts[0].hasPrefix("Standing instructions for this whole conversation:\nBe brief.") && bridge.texts[0].hasSuffix("My first message:\nhi"))
    _ = try await client.deliver("more", name: "ada-abc123", template: nil, instructions: instructions, once: once)
    #expect(bridge.texts.last == "more", "the second message carries none of it")
    // A first task the bridge never typed taught the agent nothing: the next message carries it all again.
    bridge.forgetDelivery()
    _ = try await client.deliver("again", name: "ada-abc123", template: nil, instructions: instructions, once: once)
    #expect(bridge.texts.last == HerdrClient.firstTask("again", instructions: instructions))
    // An agent with nothing to read is written to as before.
    let plain = WarmBridge(), plainClient = plain.client()
    _ = try await plainClient.warm(name: "ada-abc123", template: nil)
    _ = try await plainClient.deliver("hi", name: "ada-abc123", template: nil, once: once)
    #expect(plain.texts == [HerdrBotMessage.note + "\n\nhi"])
}

/// A message sent while the agent is still starting is given to the bridge at once, which keeps it and types it
/// when the agent is ready: the chat says that the agent is starting until it works, and the reply comes as usual.
/// A message the bridge gives up on (the agent never became ready) ends the turn with that reason, and the next
/// message carries the instructions again.
@Test func aMessageSentWhileTheAgentStartsWaitsForIt() async throws {
    let bridge = WarmBridge(), client = bridge.client()
    bridge.startSlowly(reads: 6)
    guard case .started(let agent, _) = try await client.warm(name: "ada-abc123", template: nil) else { Issue.record("started"); return }
    let early = try await client.workspace()
    #expect(agent.isStarting && HerdrAgentReadiness(agent, in: early) == .starting(program: "Agent One"))
    let heard = LockedTrace()
    let turn = try await client.deliver("hi", name: "ada-abc123", template: nil, instructions: "Be brief.", status: { heard.add($0.code) })
    #expect(!turn.launched && turn.queued && turn.starting && heard.read() == [HerdrTurnStatus.starting(program: "Agent One").code], "the message is with the bridge, which keeps it")
    #expect(bridge.texts == [HerdrClient.firstTask("hi", instructions: "Be brief.")] && bridge.launches.count == 1)
    let reply = try await client.reply(to: turn, status: { heard.add($0.code) })
    #expect(reply == "ok" && bridge.texts.count == 1 && heard.read().allSatisfy { $0 == HerdrTurnStatus.starting(program: "Agent One").code }, "typed once, and the chat said \"starting\" meanwhile")
    let later = try await client.workspace()
    #expect(HerdrAgentReadiness(later.agents.first, in: later) == .ready)

    let stuck = WarmBridge(), stuckClient = stuck.client()
    stuck.startSlowly(reads: 5); stuck.neverReady()
    _ = try await stuckClient.warm(name: "ada-abc123", template: nil)
    let lost = try await stuckClient.deliver("hi", name: "ada-abc123", template: nil, instructions: "Be brief.")
    await #expect(throws: HerdrClient.Failure.notDelivered("it did not report in time")) { try await stuckClient.reply(to: lost) }
    #expect(HerdrClient.Failure.notDelivered("It did not report in time.").localizedDescription == "It did not report in time. Choose Retry in chat once the bot is ready."
            && HerdrClient.Failure.notDelivered(nil).localizedDescription == "The bot did not get ready. Answer any terminal prompt in this chat, then choose Retry.")
    _ = try await stuckClient.deliver("again", name: "ada-abc123", template: nil, instructions: "Be brief.")
    #expect(stuck.texts.last == HerdrClient.firstTask("again", instructions: "Be brief."), "a message that was never typed taught the agent nothing")
}

/// A bridge that does not know the launch says so by refusing it: nothing is started, and a message starts the agent as before.
@Test func anOlderBridgeStartsNothingAheadOfTime() async throws {
    let bridge = WarmBridge(), client = bridge.client()
    bridge.beOlder()
    let refused = try await client.warm(name: "ada-abc123", template: nil)
    #expect(refused == .unavailable && bridge.launches.isEmpty)
    let heard = LockedTrace()
    let turn = try await client.deliver("hi", name: "ada-abc123", template: nil, instructions: "Be brief.", status: { heard.add($0.code) })
    #expect(turn.launched && bridge.launches.count == 1 && bridge.launches[0]["warm"] == nil && heard.read() == [HerdrTurnStatus.starting(program: "Agent One").code])
    let now = try await client.workspace(), live = try #require(now.agents.first)
    #expect(live.ready == nil && !live.isStarting && HerdrAgentReadiness(live, in: now) == .ready, "an agent of a bridge that says nothing about readiness is ready")
    // An agent that shows a prompt in its terminal is running but takes no message: the header says so.
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let prompting = try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t1","created_ms":5,"name":"x","state":"live","template":"tpl-one","status":{"state":"blocked"},"ready":true,"warm":true,"warm_ends_ms":9}"#.utf8))
    #expect(prompting.warmEndsMs == 9 && HerdrAgentReadiness(prompting, in: now) == .blocked(program: "Agent One") && HerdrAgentReadiness.blocked(program: nil).word == "Waiting for you in its terminal")
}

/// Opening a chat starts that bot's agent, once, and only that bot's; the switch and a server that does not start
/// agents ahead of time are respected.
@MainActor @Test func openingAChatStartsThatBotsAgentOnce() async throws {
    let bridge = WarmBridge(), (store, bot) = warmStore(bridge)
    let other = Bot(name: "Bea", backend: .herdr); store.bots.append(other)
    #expect(store.herdrKeepsReady(bot) && store.herdrFirstReplyHint(for: bot) != nil, "on unless turned off")
    store.setHerdrKeepsReady(false, for: other)
    #expect(store.warmHerdrAgent(for: other) == nil && !store.herdrKeepsReady(other))
    let first = try #require(store.warmHerdrAgent(for: bot))
    #expect(store.warmHerdrAgent(for: bot) == nil && store.herdrFirstReplyHint(for: bot) == nil, "a start that is on its way is not begun twice")
    await first.value
    #expect(bridge.launches.count == 1 && bridge.launches[0]["name"] as? String == HerdrBackend.agentName(botName: "Ada", botID: bot.id) && bridge.launches[0]["warm"] as? Bool == true)
    #expect(store.herdrReadiness[bot.id] == .ready && store.herdrReadiness[other.id] == nil && store.herdrWarming.isEmpty && store.herdrFirstReplyHint(for: bot) == nil)
    await store.warmHerdrAgent(for: bot)?.value
    #expect(bridge.launches.count == 1, "the running agent is found, not doubled")
    // What the header keeps is forgotten for a bot that is no longer watched.
    store.noteHerdrReadiness([:], watched: [other])
    #expect(store.herdrReadiness.isEmpty)
    store.noteHerdrReadiness([bot.id: .starting(program: "Agent One")], watched: [bot])
    #expect(store.herdrReadiness[bot.id]?.word == "Starting Agent One…" && HerdrAgentReadiness.ready.word == "Ready")

    let old = WarmBridge(), (older, ada) = warmStore(old)
    old.beOlder()
    await older.warmHerdrAgent(for: ada)?.value
    #expect(old.launches.isEmpty && !older.herdrStartsAhead(for: ada) && older.warmHerdrAgent(for: ada) == nil && older.herdrReadiness.isEmpty, "the server is not asked again")
    #expect(AppStore.keepsReadyCaption(bot: "Ada", program: "Agent One", available: true).hasPrefix("Ada starts when you open its chat")
            && AppStore.keepsReadyCaption(bot: "Ada", program: nil, available: false) == "This server cannot start Ada ahead of time, so it starts with your first message.")
    #expect(HerdrAgentControls.restartNote(closed: true, starting: true) == "Done. It is starting fresh now." && HerdrAgentControls.restartNote(closed: false, starting: false) == "It was not running. It starts with your next message.")
}

/// A message sent while the start is still on its way waits for it, says that the agent is starting, and is then
/// delivered to that agent, once, with the bot's instructions. No second agent is started.
@MainActor @Test func aMessageSentDuringAStartIsDeliveredOnceToThatAgent() async throws {
    let bridge = WarmBridge(), (store, bot) = warmStore(bridge)
    bridge.hold()
    let warming = try #require(store.warmHerdrAgent(for: bot))
    try await waitUntil { bridge.launchRequests == 1 }
    #expect(store.send(text: "hi", bot: bot, conversation: bot, replyToID: nil))
    let reply = try #require(bot.messages.last)
    try await waitUntil { reply.metadata[TurnKey.agent] != nil }
    #expect(reply.metadata[TurnKey.agent].flatMap(HerdrTurnStatus.init(code:)) == .starting(program: nil) && bridge.texts.isEmpty && bridge.launchRequests == 1 && store.warmHerdrAgent(for: bot) == nil)
    #expect(store.workingLine(for: bot) == "Starting the agent…", "the sidebar says the same")
    bridge.release()
    await warming.value
    try await waitUntil { store.isIdle(bot) }
    let instructions = try #require(try store.herdrBackend(for: bot).launchInstructions)
    #expect(bridge.launches.count == 1 && bridge.launchRequests == 1 && bridge.texts == [HerdrClient.firstTask("hi", instructions: instructions)], "one agent, one message, with what a first task carries")
    #expect(reply.content == "ok" && reply.turnState == .finished && reply.metadata[TurnKey.agent] == nil && store.herdrReadiness[bot.id] == .ready)
    // The next message is plain.
    #expect(store.send(text: "more", bot: bot, conversation: bot, replyToID: nil))
    try await waitUntil { store.isIdle(bot) && bridge.texts.count == 2 }
    #expect(bridge.texts.last == "more" && bridge.launches.count == 1)
}

/// An agent that was started ahead of time and has not been written to is replaced when how it would start has
/// changed; one that has had a message is left alone.
@MainActor @Test func anUnusedAgentIsReplacedWhenTheChoiceChanges() async throws {
    let bridge = WarmBridge(), (store, bot) = warmStore(bridge)
    await store.warmHerdrAgent(for: bot)?.value
    await store.warmHerdrAgent(for: bot, replacingUnused: true)?.value
    #expect(bridge.ended == 1 && bridge.launches.count == 2 && store.herdrReadiness[bot.id] == .ready)
    #expect(store.send(text: "hi", bot: bot, conversation: bot, replyToID: nil))
    try await waitUntil { store.isIdle(bot) && bridge.texts.count == 1 }
    await store.warmHerdrAgent(for: bot, replacingUnused: true)?.value
    #expect(bridge.ended == 1 && bridge.launches.count == 2, "an agent that holds a conversation keeps running")
    // With the switch off an unused agent is ended and none is started in its place.
    let quiet = WarmBridge(), (off, ada) = warmStore(quiet)
    await off.warmHerdrAgent(for: ada)?.value
    off.setHerdrKeepsReady(false, for: ada)
    await off.warmHerdrAgent(for: ada, replacingUnused: true)?.value
    #expect(quiet.ended == 1 && quiet.launches.count == 1 && off.herdrReadiness[ada.id] == nil)
}

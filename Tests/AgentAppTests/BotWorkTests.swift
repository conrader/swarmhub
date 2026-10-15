import Foundation
import Testing
@testable import AgentApp

// P42 1–5, 10: a bot working for another bot, live in its chat. A fake thread whose rows grow on each read, an injected
// clock and sleep; no network. Synthetic only.

/// The rows of Infra's `swarmhub-from-grok-jarvis` session after each read: the request, two steps, the reply.
func workStages(at t0: Date, request: String = "Is the backup disk on box 2 healthy?") -> [[BackendMessage]] {
    let user = BackendMessage(id: 10, role: "user", content: "[Message from grok-jarvis via SwarmHub]\n\(request)", createdAt: t0)
    var step1 = BackendMessage(id: 11, role: "assistant", content: "", createdAt: t0.addingTimeInterval(3), tools: ["terminal"]); step1.toolPreviews = ["df -h /backup"]
    var step2 = BackendMessage(id: 12, role: "assistant", content: "Checking the log.", createdAt: t0.addingTimeInterval(9), tools: ["read_file"]); step2.toolPreviews = ["/var/log/backup.log"]
    let reply = BackendMessage(id: 13, role: "assistant", content: "Disk at 62 %, last night's run finished.", createdAt: t0.addingTimeInterval(14), finishReason: "stop")
    return [[user], [user, step1], [user, step1, step2], [user, step1, step2, reply]]
}

/// A clock the injected sleep moves forward; the sleeps are recorded.
final class WorkClock: @unchecked Sendable {
    let date: LockedValue<Date>; let slept = LockedValue<[Duration]>([])
    init(_ start: Date) { date = LockedValue(start) }
    var now: Date { date.current }
    func sleep(_ duration: Duration) async throws {
        _ = slept.swap(slept.current + [duration])
        _ = date.swap(date.current.addingTimeInterval(Double(duration.components.seconds)))
        await Task.yield()
    }
}

@MainActor func workStore(url: URL = temporaryStore(), clock: WorkClock) -> (AppStore, Bot, Bot) {
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    store.now = { clock.now }; store.botMessages.autoLoad = false
    store.botWork.autoStart = true; store.botWorkSleep = { try await clock.sleep($0) }
    if store.bots.isEmpty {
        store.bots = [Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")]
    }
    return (store, store.bots[0], store.bots[1])
}

/// Serves `stages` in order (one more row each read), then the last forever; records what the app showed at each read.
@MainActor final class GrowingThread {
    var stages: [[BackendMessage]]; var reads = 0; var seen: [(line: String?, steps: Int, streaming: Bool)] = []
    init(_ stages: [[BackendMessage]]) { self.stages = stages }
    func attach(_ store: AppStore, recipient: Bot, session: String = "swarmhub-from-grok-jarvis") {
        store.botWork.rowsOverride = { [unowned self] bot, id in
            #expect(bot.id == recipient.id && id == session)
            let card = store.botWorkCards(in: recipient, session: session).last
            self.seen.append((store.botWorkLine(for: recipient), card?.activity?.total ?? 0, card?.isStreaming ?? false))
            defer { self.reads += 1 }
            return self.stages[min(self.reads, self.stages.count - 1)]
        }
    }
}

@MainActor func finishWatches(_ store: AppStore) async {
    for task in Array(store.botWork.pollers.values) { await task.value }
}

@Test func theLastTurnIsReadWithItsStepsAndReply() throws {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000), stages = workStages(at: t0)
    let mid = try #require(BotWorkReader.lastTurn(stages[2]))
    #expect(mid.origin == .bot("grok-jarvis") && mid.request == "Is the backup disk on box 2 healthy?" && !mid.finished && mid.reply == nil)
    #expect(mid.activity?.steps.map(\.name) == ["terminal", "read_file"] && mid.activity?.steps.map(\.preview) == ["df -h /backup", "/var/log/backup.log"])
    #expect(mid.activity?.steps.last?.isRunning == true && mid.activity?.steps.first?.isRunning == false, "the newest step runs until the reply")
    let done = try #require(BotWorkReader.lastTurn(stages[3]))
    #expect(done.finished && done.reply == "Disk at 62 %, last night's run finished." && done.activity?.steps.allSatisfy { !$0.isRunning } == true)
    #expect(BotWorkReader.lastTurn(stages[3], after: t0.addingTimeInterval(1)) == nil, "an exchange older than the step is not this one")
    #expect(BotWorkOrigin.header("[Reply from grok-infra via SwarmHub]\nDone.")?.origin == .reply("grok-infra"))
    #expect(BotWorkOrigin(raw: BotWorkOrigin.routine("Morning report").raw) == .routine("Morning report"))
    // The header tells a reply from a message, but never names a sender the session doesn't have.
    #expect(AppStore.trustedOrigin(.reply("grok-infra"), watched: .bot("grok-infra")) == .reply("grok-infra"))
    #expect(AppStore.trustedOrigin(.bot("grok-boss"), watched: .bot("grok-jarvis")) == .bot("grok-jarvis"))
    #expect(AppStore.trustedOrigin(nil, watched: .routine("Daily")) == .routine("Daily"))
}

@Test func toolCallsKeepWhatTheyRanOn() throws {
    let row: [String: Any] = ["id": 5, "role": "assistant", "content": "", "created_at": 1_800_000_000.0,
                              "tool_calls": [["function": ["name": "terminal", "arguments": #"{"command":"df -h /backup","timeout":30}"#]],
                                             ["function": ["name": "web_extract", "arguments": ["urls": "https://example.org"]]],
                                             ["function": ["name": "skill_view", "arguments": ["name": "swarmhub-messages"]]]]]
    let message = try #require(HermesBackend.workRow(row))
    #expect(message.tools == ["terminal", "web_extract", "skill_view"] && message.toolPreviews == ["df -h /backup", "https://example.org", "swarmhub-messages"])
    #expect(HermesBackend.parseMessage(row, toolCalls: true)?.toolPreviews == [], "reconcile reads stay as they were")
}

@Test @MainActor func aLiveCardUnfoldsAndTheReplyEndsIt() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, _, infra) = workStore(clock: clock)
    let thread = GrowingThread(workStages(at: clock.now)); thread.attach(store, recipient: infra)
    store.applyBotThreadRows([], recipient: infra)
    store.applyBotThreadRows([BotThreadRow(sessionID: "swarmhub-from-grok-jarvis", sender: "grok-jarvis", mark: "1", updatedAt: clock.now, preview: nil)], recipient: infra)
    await finishWatches(store)
    #expect(thread.reads == 4, "one read per row, stopped at the reply")
    #expect(thread.seen.map(\.steps) == [0, 0, 1, 2], "the steps unfold in order")
    #expect(thread.seen.dropFirst().allSatisfy { $0.line == "Working… · for Jarvis" && $0.streaming }, "working for the whole run")
    let card = try #require(infra.messages.last)
    #expect(infra.messages.count == 1 && card.presentation == .botMessage && card.content == "Jarvis wrote to Infra", "the arrival line became the card")
    #expect(card.metadata[BotWorkKey.request] == "Is the backup disk on box 2 healthy?" && card.metadata[BotWorkKey.reply] == "Disk at 62 %, last night's run finished.")
    #expect(card.activity?.steps.map(\.name) == ["terminal", "read_file"] && !card.isStreaming)
    #expect(store.botWorkLine(for: infra) == nil && store.workingForOthersLine(for: infra) == nil, "back to idle")
    #expect(clock.slept.current == [.seconds(2), .seconds(2), .seconds(2)])
    #expect(BotWorkCopy.wokenBy(.bot("grok-jarvis"), name: store.displayName(forProfile:)) == "Woken by: Jarvis")
}

@Test @MainActor func aQuietRunBacksOffAndStopsAfterThirtyMinutes() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, _, infra) = workStore(clock: clock)
    let thread = GrowingThread(Array(workStages(at: clock.now).prefix(2))); thread.attach(store, recipient: infra)
    store.watchBotWork(infra, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    await finishWatches(store)
    let slept = clock.slept.current
    #expect(slept.prefix(30).allSatisfy { $0 == .seconds(2) } && slept.contains(.seconds(10)), "2 s, then 10 s after a quiet minute")
    #expect(slept.drop { $0 == .seconds(2) }.allSatisfy { $0 == .seconds(10) })
    #expect(clock.now.timeIntervalSince1970 - 1_800_000_000 >= 1_800 && clock.now.timeIntervalSince1970 - 1_800_000_000 < 1_812, "stopped at 30 min")
    let card = try #require(infra.messages.last)
    #expect(!card.isStreaming && card.metadata[BotWorkKey.reply] == BotWorkCopy.stopped && store.botWorkLine(for: infra) == nil)
}

@Test @MainActor func theSendersStepStartsTheCardAndSkipsTheOlderExchange() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, jarvis, infra) = workStore(clock: clock)
    // An earlier exchange already on a card; the new request lands on the third read.
    let old = workStages(at: clock.now.addingTimeInterval(-30), request: "earlier")[3]
    infra.messages = [ChatMessage(role: .system, content: "Jarvis wrote to Infra", presentation: .botMessage,
                                  metadata: [BotMessageKey.session: "swarmhub-from-grok-jarvis", BotWorkKey.requestID: "10", BotWorkKey.origin: "bot:grok-jarvis"])]
    let fresh = workStages(at: clock.now.addingTimeInterval(4)).map { rows in rows.map { BackendMessage(id: ($0.id ?? 0) + 100, role: $0.role, content: $0.content, createdAt: $0.createdAt, finishReason: $0.finishReason, tools: $0.tools) } }
    let thread = GrowingThread([old, old] + fresh); thread.attach(store, recipient: infra)
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1", command: liveBotMsgCommand), at: clock.now)
    store.noteStartedBotMessageSteps(before: nil, after: activity, sender: jarvis)
    #expect(store.botWork.pollers.count == 1)
    await finishWatches(store)
    #expect(infra.messages.count == 2, "a new card for the new exchange; the older one stays")
    #expect(infra.messages[0].metadata[BotWorkKey.reply] == nil && infra.messages[1].metadata[BotWorkKey.requestID] == "110")
    #expect(infra.messages[1].metadata[BotWorkKey.reply] == "Disk at 62 %, last night's run finished.")
}

@Test @MainActor func aRestartMidRunShowsTheLiveCardAgain() async throws {
    let url = temporaryStore(), clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let row = BotThreadRow(sessionID: "swarmhub-from-grok-jarvis", sender: "grok-jarvis", mark: "3", updatedAt: clock.now.addingTimeInterval(-120), preview: nil)
    do {
        let (store, _, infra) = workStore(url: url, clock: clock); store.botWork.autoStart = false
        store.applyBotThreadRows([row], recipient: infra); store.save()
    }
    // Relaunch: same mark (no arrival), changed 2 min ago, still mid-run.
    let (store, _, infra) = workStore(url: url, clock: clock)
    let messagesBefore = infra.messages.count
    let thread = GrowingThread(Array(workStages(at: clock.now.addingTimeInterval(-120))[1...])); thread.attach(store, recipient: infra)
    store.applyBotThreadRows([row], recipient: infra)
    #expect(store.botWork.pollers.count == 1, "a thread changed in the last 30 min is checked")
    await finishWatches(store)
    #expect(thread.seen.dropFirst().allSatisfy { $0.line == "Working… · for Jarvis" })
    #expect(infra.messages.count == messagesBefore && infra.messages.last?.metadata[BotWorkKey.reply] != nil, "the arrival line became the card")
    // A second list in the same launch checks nothing; a finished run after a restart is not drawn again.
    store.applyBotThreadRows([row], recipient: infra)
    #expect(store.botWork.pollers.isEmpty)
    let (again, _, infra2) = workStore(url: url, clock: clock)
    let finished = GrowingThread([workStages(at: clock.now.addingTimeInterval(-120))[3]]); finished.attach(again, recipient: infra2)
    infra2.messages = []
    again.applyBotThreadRows([row], recipient: infra2)
    await finishWatches(again)
    #expect(infra2.messages.isEmpty, "a finished run after a restart is not shown as new")
}

@Test @MainActor func twoRecipientsWorkAtOnce() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, jarvis, infra) = workStore(clock: clock)
    let coder = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder"); store.bots.append(coder)
    let stages = Array(workStages(at: clock.now).prefix(2))
    store.botWork.rowsOverride = { _, _ in stages[1] }
    store.watchBotWork(infra, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    store.watchBotWork(coder, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    store.watchBotWork(coder, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    #expect(store.botWork.pollers.count == 2, "one poller per thread")
    for _ in 0..<20 where store.botWorkLive(for: infra) == nil || store.botWorkLive(for: coder) == nil { await Task.yield() }
    #expect(store.botWorkLine(for: infra) == "Working… · for Jarvis" && store.botWorkLine(for: coder) == "Working… · for Jarvis")
    #expect(store.botMessagePollInterval(for: jarvis) == 5, "the bot-message poll runs every 5 s while a bot on the connection works")
    store.stopBotWork()
    #expect(store.botMessagePollInterval(for: jarvis) == 20)
}

@Test @MainActor func noPollerForADisconnectedConnection() {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, _, infra) = workStore(clock: clock)
    store.botMessages.errors[infra.id] = "synthetic box is down"
    store.watchBotWork(infra, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    #expect(store.botWork.pollers.isEmpty)
    store.botMessages.errors[infra.id] = nil; store.botWork.autoStart = false
    store.watchBotWork(infra, target: .session("swarmhub-from-grok-jarvis"), origin: .bot("grok-jarvis"))
    #expect(store.botWork.pollers.isEmpty, "off in tests and renders unless switched on")
}

@Test @MainActor func theConversationShowsTheWholeExchange() async throws {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000), key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
    let first = workStages(at: t0)[3]
    let second = workStages(at: t0.addingTimeInterval(600), request: "And box 3?")[2].map {
        BackendMessage(id: ($0.id ?? 0) + 100, role: $0.role, content: $0.content, createdAt: $0.createdAt, finishReason: $0.finishReason, tools: $0.tools)
    }
    let lines = AppStore.threadLines(first + second, key: key)
    #expect(lines.map(\.author) == ["grok-jarvis", "grok-infra", "grok-jarvis", "grok-infra"])
    #expect(lines.map(\.text) == ["Is the backup disk on box 2 healthy?", "Checking the log.\n\nDisk at 62 %, last night's run finished.", "And box 3?", "Checking the log."])
    #expect(lines[1].activity?.steps.map(\.name) == ["terminal", "read_file"] && lines[1].activity?.steps.allSatisfy { !$0.isRunning } == true)
    #expect(lines[3].activity?.steps.last?.isRunning == true, "the answer still running shows its current step")
    // The sheet reads the recipient's session through the same read as the live card.
    let clock = WorkClock(t0)
    let (store, _, infra) = workStore(clock: clock)
    store.botWork.rowsOverride = { bot, session in
        #expect(bot.id == infra.id && session == "swarmhub-from-grok-jarvis")
        return first + second
    }
    await store.loadThread(key)
    #expect(store.knownThreadLines(key) == lines)
    #expect(BotThreadKey(from: "grok-jarvis", to: "grok-infra", session: "swarmhub-from-grok-jarvis") == key, "the usual session is the plain key")
}

@Test @MainActor func aLiveCardIsNoTurnOfTheChat() throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, _, infra) = workStore(clock: clock)
    let turn = try #require(BotWorkReader.lastTurn(workStages(at: clock.now)[2]))
    store.applyBotWork(turn, bot: infra, session: "swarmhub-from-grok-jarvis", origin: .bot("grok-jarvis"),
                       key: .init(bot: infra.id, target: "swarmhub-from-grok-jarvis"), start: clock.now)
    #expect(infra.messages.last?.isStreaming == true && !store.isWorking(infra))
    #expect(!store.isStreamingIn(infra), "the recipient's own chat still reconciles while the card is live")
    #expect(HistoryReconciler.LocalRow(try #require(infra.messages.last)).isTextTurn == false, "never paired with the main session's turns")
}

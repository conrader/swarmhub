import Foundation
import Testing
@testable import AgentApp

// A /loop or /goal in a Bot Chat goes to the box as a Hermes routine when SwarmHub quits, and comes back at launch:
// paused first, its rounds counted from the Bot Chat, deleted, and continued here with nothing run twice.

private final class Bodies: @unchecked Sendable {
    private let lock = NSLock(); private var items: [[String: Any]] = []
    func add(_ body: [String: Any]) { lock.withLock { items.append(body) } }
    var all: [[String: Any]] { lock.withLock { items } }
}

/// The box's Bot Chat session `main-session`: its rows (served oldest first, newest window like Hermes), or `status`
/// (503 a failed read, 404 no session). `legacy`: the box has no session reads at all.
private final class BoxSession: @unchecked Sendable {
    private let lock = NSLock(); private var rows: [[String: Any]] = []; private var code = 200; private var noSessions = false
    var status: Int { get { lock.withLock { code } } set { lock.withLock { code = newValue } } }
    var legacy: Bool { get { lock.withLock { noSessions } } set { lock.withLock { noSessions = newValue } } }
    func add(_ role: String, _ content: String, at date: Date) {
        lock.withLock { rows.append(["id": rows.count + 1, "role": role, "content": content, "created_at": date.timeIntervalSince1970, "finish_reason": "stop"]) }
    }
    func handle(_ request: URLRequest) -> (Int, Any)? {
        guard let url = request.url else { return nil }
        if url.path.hasSuffix("/v1/capabilities") { return (200, ["features": ["session_chat_streaming": !legacy]]) }
        guard url.path.hasSuffix("/api/sessions/main-session/messages") else { return nil }
        let (status, all) = lock.withLock { (code, rows) }
        if status == 404 { return (404, ["error": ["code": "session_not_found"]]) }
        guard status == 200 else { return (status, ["error": "unavailable"]) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? all.count
        let offset = query.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
        let end = max(0, all.count - offset), page = Array(all[max(0, end - limit)..<end])
        return (200, ["object": "list", "data": page] as [String: Any])
    }
}

@MainActor private func handoffStore(botChat: Bool = true) -> (AppStore, Bot, FakeJobsServer, Bodies, String, BoxSession) {
    let server = FakeJobsServer(), bodies = Bodies(), box = BoxSession()
    let (host, session) = MockHermesProtocol.serve { request in
        if let answer = box.handle(request) { return answer }
        var copy = request
        if request.httpMethod == "POST", let body = jsonBody(request) {
            bodies.add(body); copy.httpBody = try? JSONSerialization.data(withJSONObject: body); copy.httpBodyStream = nil
        }
        return server.handle(copy)
    }
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": "jarvis-key"]), defaults: defaults, hermesSession: session)
    let bot = Bot(name: "Jarvis", backend: .hermes, hermesProfile: server.profile)
    bot.hermesSessionID = "main-session"
    store.bots = [bot]
    if botChat { store.heartbeatSettings.botChats[bot.id.uuidString] = "main-session" }
    store.save()
    return (store, bot, server, bodies, host, box)
}

/// What Hermes appends to the Bot Chat on the box for a `bot-chat:` routine run, and the bot's reply. SwarmHub is closed,
/// so the chat on the Mac has neither until the reclaim reads the box.
private func boxRound(_ box: BoxSession, job: String, reply: String, at date: Date) {
    box.add("user", "[Cronjob \"\(job)\" output — scheduled job, not the user. Reply to it.]\nprompt", at: date)
    box.add("assistant", reply, at: date.addingTimeInterval(5))
}

/// A turn both the Mac and the box hold (the chat before the quit).
@MainActor private func sharedTurn(_ bot: Bot, _ box: BoxSession, ask: String, reply: String, at date: Date) {
    bot.messages += [ChatMessage(role: .user, content: ask, createdAt: date),
                     ChatMessage(role: .assistant, content: reply, createdAt: date.addingTimeInterval(5), turnState: .finished)]
    box.add("user", ask, at: date); box.add("assistant", reply, at: date.addingTimeInterval(5))
}

@Test @MainActor func aBotChatLoopRunsOnTheBoxWhileClosedAndComesBackWithoutRunningTwice() async throws {
    let (store, bot, server, bodies, host, box) = handoffStore()
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "check the build", interval: 600, timesLeft: 3, until: nil, nextAt: Date()))
    store.handOffForQuit(budget: 5)
    let name = AppStore.handoffName(.loop, chat: bot.id)
    let body = try #require(bodies.all.first)
    #expect(body["name"] as? String == name && body["schedule"] as? String == "every 10m" && body["deliver"] as? String == "bot-chat:grok-jarvis")
    #expect(body["repeat"] as? Int == 3 && (body["prompt"] as? String)?.contains("\n-----\ncheck the build\n-----") == true)
    let handoff = try #require(store.automations[bot.id]?.boxHandoff)
    #expect(handoff.kind == .loop && handoff.jobID == server.jobIDs.first)

    // Launch: nothing runs here while the box holds it.
    let messages = bot.messages.count
    store.automationTick()
    #expect(bot.messages.count == messages && store.automations[bot.id]?.loop?.awaitingReply == false)

    boxRound(box, job: name, reply: "Build is green.", at: handoff.handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs()
    let lines = requestLines(host)
    let pause = try #require(lines.firstIndex(of: "POST /p/grok-jarvis/api/jobs/\(handoff.jobID!)/pause"))
    let read = try #require(lines.firstIndex { $0.contains("/api/sessions/main-session/messages") })
    let delete = try #require(lines.firstIndex(of: "DELETE /p/grok-jarvis/api/jobs/\(handoff.jobID!)"))
    #expect(pause < read && read < delete && server.jobIDs.isEmpty, "paused before anything else, read, then deleted")
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(store.automations[bot.id]?.boxHandoff == nil && loop.runs == 1 && loop.timesLeft == 2 && loop.nextAt >= Date().addingTimeInterval(-5))
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(1) })
    #expect(bot.messages.first { CronDeliveryRow.jobName($0.content) == name }?.metadata[AutomationKey.display] == "Loop (on the box)")
}

@Test @MainActor func aGoalGetsAFifteenMinuteRoundWithinItsBudgetAndADoneReplyOnTheBoxEndsIt() async throws {
    let (store, bot, server, bodies, _, box) = handoffStore()
    store.automations[bot.id] = ChatAutomation(goal: GoalRun(text: "Write the release notes", maxRounds: 20, startedAt: Date(), maxDuration: 7200, codingEvidence: false))
    store.handOffForQuit(budget: 5)
    let body = try #require(bodies.all.first)
    #expect(body["schedule"] as? String == "every 15m" && [7, 8].contains(body["repeat"] as? Int ?? 0), "two hours of 15-minute rounds")
    #expect((body["prompt"] as? String)?.contains("Continue toward the goal: Write the release notes") == true)
    let handoff = try #require(store.automations[bot.id]?.boxHandoff)
    boxRound(box, job: handoff.jobName, reply: "Drafted.", at: handoff.handedAt.addingTimeInterval(900))
    boxRound(box, job: handoff.jobName, reply: """
        The notes are in the chat above.
        ```swarmhub
        {"op":"goal","status":"done","summary":"Release notes written","evidence":{"deliverable":"in this chat"}}
        ```
        """, at: handoff.handedAt.addingTimeInterval(1800))
    await store.reclaimHandoffs()
    let goal = try #require(store.automations[bot.id]?.goal)
    #expect(goal.state == .done && goal.round == 2 && server.jobIDs.isEmpty)
    #expect(bot.messages.contains { $0.content == HandoffCopy.goalRan(2) })
}

@Test @MainActor func threadsAndChatsWithoutABotChatStayInTheApp() async throws {
    let (store, bot, _, bodies, _, _) = handoffStore(botChat: false)
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 300, timesLeft: nil, until: nil, nextAt: Date()))
    store.handOffForQuit(budget: 5)
    #expect(bodies.all.isEmpty && store.automations[bot.id]?.boxHandoff == nil)
    #expect(store.handoffPlans(now: Date()).isEmpty)
}

@Test @MainActor func anUnreachableBoxKeepsTheLoopAndARoutineTheQuitDidNotRecordIsFoundByName() async throws {
    let (store, bot, server, _, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id)
    // The quit gave up before the box answered: no id recorded, but the box made the routine.
    server.add(jobPayload(id: "0000000abc01", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: nil, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: nil, handedAt: Date()))
    server.listStatus = 503
    await store.reclaimHandoffs()
    #expect(store.automations[bot.id]?.boxHandoff != nil && server.job("0000000abc01")?["enabled"] as? Bool == true, "kept on the box")
    server.listStatus = 200
    await store.reclaimHandoffs()
    #expect(store.automations[bot.id]?.boxHandoff == nil && server.jobIDs.isEmpty && store.automations[bot.id]?.loop != nil)
}

@Test @MainActor func aLoopStoppedWhileItWasOnTheBoxStillHasItsRoutineDeleted() async throws {
    let (store, bot, server, _, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id)
    server.add(jobPayload(id: "0000000abc02", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: nil, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc02", handedAt: Date()))
    store.endLoop(in: bot, line: "Loop stopped.")
    #expect(store.automations[bot.id] != nil, "kept until the box's routine is gone")
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id] == nil)
}

@Test @MainActor func aBotChatReadThatFailsKeepsTheRoutinePausedOnTheBoxAndSaysWhyOnce() async throws {
    let (store, bot, server, _, host, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc03", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc03", handedAt: handedAt))
    // The Mac holds a box round the box session lacks.
    bot.messages += [ChatMessage(role: .user, content: "[Cronjob \"\(name)\" output — scheduled job, not the user. Reply to it.]\nprompt", createdAt: handedAt.addingTimeInterval(600)),
                     ChatMessage(role: .assistant, content: "pong", createdAt: handedAt.addingTimeInterval(605), turnState: .finished)]
    box.status = 503
    await store.reclaimHandoffs() // the read fails
    box.status = 200
    await store.reclaimHandoffs() // the box session is empty: its turns cannot be merged
    #expect(server.job("0000000abc03")?["enabled"] as? Bool == false, "kept on the box, paused")
    #expect(!requestLines(host).contains { $0.hasPrefix("DELETE ") }, "never deleted before the chat is read")
    let automation = try #require(store.automations[bot.id])
    #expect(automation.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop))
    #expect(automation.loop?.runs == 0 && automation.loop?.timesLeft == 3, "nothing counted, nothing resumed")
    #expect(bot.messages.filter { $0.content == HandoffCopy.notReconciled(.loop) }.count == 1, "said once")
    #expect(bot.messages.filter { $0.content.hasPrefix("Hermes history was not merged") }.count == 1, "the reconcile's note too")
    #expect(!bot.messages.contains { $0.content == HandoffCopy.loopRan(1) })
}

@Test @MainActor func roundsTheBoxRanButTheChatLacksAreWaitedForThenTakenBack() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc04", name: name, schedule: "every 10m"))
    server.set("0000000abc04", ["repeat": ["times": 3, "completed": 2]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc04", handedAt: handedAt))
    boxRound(box, job: name, reply: "first", at: handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs()
    #expect(server.job("0000000abc04")?["enabled"] as? Bool == false && store.automations[bot.id]?.boxHandoff?.waitingSince != nil,
            "paused; the second round's reply is not in the chat yet")
    #expect(store.automations[bot.id]?.loop?.runs == 0)
    boxRound(box, job: name, reply: "second", at: handedAt.addingTimeInterval(1_200))
    await store.reclaimHandoffs()
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && loop.runs == 2 && loop.timesLeft == 1)
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(2) })
}

@Test @MainActor func roundsWhoseRepliesNeverArriveKeepTheRoutinePastTheWaitUntilTheUserTakesItOver() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc05", name: name, schedule: "every 10m"))
    server.set("0000000abc05", ["repeat": ["times": 3, "completed": 2]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc05", handedAt: handedAt))
    boxRound(box, job: name, reply: "first", at: handedAt.addingTimeInterval(600))
    store.loopCommand("takeover", bot: bot, conversation: bot)
    #expect(bot.messages.last?.content == HandoffCopy.nothingToTakeOver(.loop), "nothing is missing yet")
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc05"] && store.automations[bot.id]?.boxHandoff != nil)
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs(); await store.reclaimHandoffs()
    // The missing round's reply could have met an --until: not taken over by itself; the chat says so once.
    #expect(server.jobIDs == ["0000000abc05"] && store.automations[bot.id]?.loop?.runs == 0)
    #expect(bot.messages.filter { $0.content == HandoffCopy.roundsMissing(.loop) }.count == 1)
    store.loopCommand("takeover", bot: bot, conversation: bot)
    #expect(bot.messages.last?.content == HandoffCopy.takingOver(.loop))
    await store.reclaimHandoffs()
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && loop.runs == 2 && loop.timesLeft == 1, "the box's count wins")
}

@Test @MainActor func aRunStillInFlightIsNeverDeletedHoweverLongItRunsAndPastAnHourTheChatSaysSo() async throws {
    let (store, bot, server, _, host, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc06", name: name, schedule: "every 10m"))
    server.set("0000000abc06", ["fire_claim": ["by": "scheduler", "at": "2026-10-23T08:00:00+00:00"]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc06", handedAt: handedAt))
    await store.reclaimHandoffs()
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc06"] && store.automations[bot.id]?.boxHandoff != nil, "its round is not counted yet")
    #expect(!bot.messages.contains { $0.content == HandoffCopy.stillRunning(.loop) })
    for hours in [1.1, 5.0, 30.0] {
        store.now = { Date().addingTimeInterval(hours * 3_600) }
        await store.reclaimHandoffs()
    }
    #expect(server.jobIDs == ["0000000abc06"] && !requestLines(host).contains { $0.hasPrefix("DELETE ") }, "never deleted while it runs")
    let waiting = try #require(store.automations[bot.id])
    #expect(waiting.boxHandoff?.lastError == HandoffCopy.stillRunning(.loop) && waiting.loop?.runs == 0 && waiting.loop?.awaitingReply == false)
    #expect(bot.messages.filter { $0.content == HandoffCopy.stillRunning(.loop) }.count == 1, "said once")
    // The run ends; the box counted it but its reply is not in the chat: a fresh wait for it, then the box's count.
    server.set("0000000abc06", ["fire_claim": NSNull(), "repeat": ["times": 3, "completed": 1], "last_run_at": "2026-10-23T09:00:00+00:00"])
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc06"] && store.automations[bot.id]?.boxHandoff?.waitingFor == "behind", "the run's wait is not the reply's")
    store.now = { Date().addingTimeInterval(30 * 3_600 + AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc06"] && store.automations[bot.id]?.boxHandoff?.lastError == HandoffCopy.roundsMissing(.loop))
    store.loopCommand("takeover", bot: bot, conversation: bot)
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 1)
}

@Test @MainActor func aStopWhileARunIsInFlightLongPastTheWaitStillEndsItOnTheBox() async throws {
    let (store, bot, server, _, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id)
    server.add(jobPayload(id: "0000000abc07", name: name, schedule: "every 10m"))
    server.set("0000000abc07", ["fire_claim": ["by": "scheduler", "at": "2026-10-23T08:00:00+00:00"]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: nil, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc07", handedAt: Date().addingTimeInterval(-600)))
    await store.reclaimHandoffs()
    store.now = { Date().addingTimeInterval(2 * 3_600) }
    await store.reclaimHandoffs()
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc07"] && bot.messages.filter { $0.content == HandoffCopy.stillRunning(.loop) }.count == 1)
    store.endLoop(in: bot, line: "Loop stopped.")
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id] == nil, "the user's stop deletes it; nothing resumes here")
}

@Test @MainActor func theBoxReadMergesRealHistoryAndOnlyThenIsTheRoutineDeletedAndCounted() async throws {
    let (store, bot, server, _, host, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    // The chat before the quit, on the Mac and on the box alike; then two box rounds only the box has.
    sharedTurn(bot, box, ask: "watch the deploy", reply: "Watching it.", at: handedAt.addingTimeInterval(-120))
    boxRound(box, job: name, reply: "Deploy still rolling.", at: handedAt.addingTimeInterval(600))
    boxRound(box, job: name, reply: "Deploy is live.", at: handedAt.addingTimeInterval(1_200))
    server.add(jobPayload(id: "0000000abc08", name: name, schedule: "every 10m"))
    server.set("0000000abc08", ["repeat": ["times": 5, "completed": 2], "last_run_at": "2026-10-23T09:00:00+00:00"])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "check the deploy", interval: 600, timesLeft: 5, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc08", handedAt: handedAt))
    #expect(!bot.messages.contains { $0.content == "Deploy is live." })
    await store.reclaimHandoffs()
    let lines = requestLines(host)
    let read = try #require(lines.firstIndex { $0.contains("/api/sessions/main-session/messages") })
    let delete = try #require(lines.firstIndex(of: "DELETE /p/grok-jarvis/api/jobs/0000000abc08"))
    #expect(read < delete && server.jobIDs.isEmpty)
    let texts = bot.messages.filter { $0.role != .system }.map(\.content)
    #expect(texts.filter { $0 == "Watching it." }.count == 1, "the shared turn is not doubled")
    #expect(texts.suffix(2) == ["[Cronjob \"\(name)\" output — scheduled job, not the user. Reply to it.]\nprompt", "Deploy is live."], "the box's rounds are merged in")
    #expect(!bot.messages.contains { $0.content.hasPrefix("Hermes history was not merged") })
    let automation = try #require(store.automations[bot.id])
    #expect(automation.boxHandoff == nil && automation.loop?.runs == 2 && automation.loop?.timesLeft == 3)
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(2) })
}

@Test @MainActor func aBoxWithoutSessionReadsIsNeverTakenBackUnread() async throws {
    let (store, bot, server, _, host, box) = handoffStore()
    box.legacy = true
    let name = AppStore.handoffName(.loop, chat: bot.id)
    server.add(jobPayload(id: "0000000abc09", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc09", handedAt: Date().addingTimeInterval(-1_800)))
    await store.reclaimHandoffs()
    await store.reclaimHandoffs()
    #expect(server.job("0000000abc09")?["enabled"] as? Bool == false && !requestLines(host).contains { $0.hasPrefix("DELETE ") }, "kept on the box, paused")
    #expect(store.automations[bot.id]?.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop) && store.automations[bot.id]?.loop?.runs == 0)
    #expect(bot.messages.filter { $0.content == HandoffCopy.notReconciled(.loop) }.count == 1)
}

@Test @MainActor func aMissingBoxSessionIsTakenBackOnlyWhenTheRoutineNeverRan() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    box.status = 404
    let name = AppStore.handoffName(.loop, chat: bot.id)
    server.add(jobPayload(id: "0000000abc10", name: name, schedule: "every 10m", lastRunAt: "2026-10-23T09:00:00+00:00"))
    server.set("0000000abc10", ["repeat": ["times": 3, "completed": 1]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc10", handedAt: Date().addingTimeInterval(-1_800)))
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc10"] && store.automations[bot.id]?.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop),
            "it ran, but the box has no history of it: unknown, so kept")
    // A routine that never ran has nothing in the chat to miss.
    server.set("0000000abc10", ["repeat": ["times": 3, "completed": 0], "last_run_at": NSNull()])
    await store.reclaimHandoffs()
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && loop.runs == 0 && loop.timesLeft == 3)
}

@Test @MainActor func roundsWithTheSameTextAsEarlierOnesAreStillMergedAcrossTicksAndQuits() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), first = Date().addingTimeInterval(-7_200)
    func handOff(_ id: String, at date: Date) {
        server.add(jobPayload(id: id, name: name, schedule: "every 10m"))
        store.automations[bot.id]?.boxHandoff = BoxHandoff(kind: .loop, jobName: name, jobID: id, handedAt: date)
    }
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: nil, until: nil, nextAt: Date()))
    // First quit: one round, taken back.
    handOff("0000000abc11", at: first)
    boxRound(box, job: name, reply: "pong", at: first.addingTimeInterval(600))
    await store.reclaimHandoffs()
    #expect(store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 1)
    // Second quit: the same routine name, the same delivery text, the same reply; one round in, one still in flight.
    let second = Date().addingTimeInterval(-1_800)
    handOff("0000000abc12", at: second)
    server.set("0000000abc12", ["fire_claim": ["by": "scheduler", "at": "2026-10-23T08:00:00+00:00"]])
    boxRound(box, job: name, reply: "pong", at: second.addingTimeInterval(600))
    await store.reclaimHandoffs()
    #expect(store.automations[bot.id]?.boxHandoff != nil, "a run is in flight")
    boxRound(box, job: name, reply: "pong", at: second.addingTimeInterval(1_200))
    server.set("0000000abc12", ["fire_claim": NSNull(), "repeat": ["times": NSNull(), "completed": 2]])
    await store.reclaimHandoffs()
    let deliveries = bot.messages.filter { CronDeliveryRow.jobName($0.content) == name }
    #expect(deliveries.count == 3 && bot.messages.filter { $0.role == .assistant && $0.content == "pong" }.count == 3, "every box round is in the chat once")
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 3)
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(2) })
}

@Test @MainActor func aLongHandoffIsReadToItsFirstRoundBeforeItIsTakenBack() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-50_000)
    sharedTurn(bot, box, ask: "keep an eye on the queue", reply: "On it.", at: handedAt.addingTimeInterval(-120))
    // 45 rounds: 90 box rows, past the newest 60-row window an ordinary pass reads.
    for round in 1...45 { boxRound(box, job: name, reply: "Queue depth \(round).", at: handedAt.addingTimeInterval(Double(round) * 600)) }
    server.add(jobPayload(id: "0000000abc13", name: name, schedule: "every 10m", lastRunAt: "2026-10-23T09:00:00+00:00"))
    server.set("0000000abc13", ["repeat": ["times": NSNull(), "completed": 45]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "check the queue", interval: 600, timesLeft: nil, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc13", handedAt: handedAt))
    await store.reclaimHandoffs()
    #expect(bot.messages.filter { CronDeliveryRow.jobName($0.content) == name }.count == 45 && bot.messages.contains { $0.content == "Queue depth 1." })
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 45)
}

@Test @MainActor func aMissingSessionWithNoRoutineLeftOnTheBoxIsUnknownAndKept() async throws {
    let (store, bot, _, _, _, box) = handoffStore()
    box.status = 404
    let name = AppStore.handoffName(.loop, chat: bot.id)
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc14", handedAt: Date().addingTimeInterval(-1_800)))
    await store.reclaimHandoffs()
    let automation = try #require(store.automations[bot.id])
    #expect(automation.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop) && automation.loop?.runs == 0, "the routine may have run and gone")
}

@Test @MainActor func aChatThatStaysBusyIsReadLaterAndPastTheWaitSaysSoOnce() async throws {
    let (store, bot, server, _, host, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id)
    server.add(jobPayload(id: "0000000abc15", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc15", handedAt: Date().addingTimeInterval(-1_800)))
    let streaming = ChatMessage(role: .assistant, content: "…", isStreaming: true)
    bot.messages.append(streaming)
    await store.reclaimHandoffs()
    #expect(store.automations[bot.id]?.boxHandoff?.lastError == nil, "busy: nothing said yet")
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs(); await store.reclaimHandoffs()
    #expect(bot.messages.filter { $0.content == HandoffCopy.notReconciled(.loop) }.count == 1 && !requestLines(host).contains { $0.hasPrefix("DELETE ") })
    bot.messages.removeAll { $0 === streaming } // the turn ended (its row is the box's to bring back)
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil)
}

@Test @MainActor func anOldDeliveryTheChatNeverHeldDoesNotHoldBackALaterHandoff() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    // Older than anything the Mac holds: the reconcile leaves it out, as it always has.
    boxRound(box, job: name, reply: "pong from last week", at: handedAt.addingTimeInterval(-7 * 86_400))
    sharedTurn(bot, box, ask: "ping me", reply: "Will do.", at: handedAt.addingTimeInterval(-120))
    boxRound(box, job: name, reply: "pong", at: handedAt.addingTimeInterval(600))
    server.add(jobPayload(id: "0000000abc16", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc16", handedAt: handedAt))
    await store.reclaimHandoffs()
    #expect(!bot.messages.contains { $0.content == "pong from last week" })
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 1)
}

@Test @MainActor func aShortBoxReplyEqualToALocalOnlyReplyIsStillAddedAndCounted() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    sharedTurn(bot, box, ask: "ping me", reply: "Will do.", at: handedAt.addingTimeInterval(-300))
    // A turn only the Mac holds, with the same short reply the box's round will give.
    bot.messages += [ChatMessage(role: .user, content: "still there?", createdAt: handedAt.addingTimeInterval(-120)),
                     ChatMessage(role: .assistant, content: "pong", createdAt: handedAt.addingTimeInterval(-115), turnState: .finished)]
    boxRound(box, job: name, reply: "pong", at: handedAt.addingTimeInterval(600))
    server.add(jobPayload(id: "0000000abc17", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc17", handedAt: handedAt))
    await store.reclaimHandoffs()
    #expect(bot.messages.filter { $0.role == .assistant && $0.content == "pong" }.count == 2, "the box's round is not taken for the local reply")
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.loop?.runs == 1)
}

/// A round of this handoff read from the box before (its rows carry the box's ids), whose reply in the chat is not the
/// box's: `reply` is what the chat holds, the box holds "Build is green.".
@MainActor private func staleRound(reply: String, state: TurnState) async -> (AppStore, Bot, FakeJobsServer, String) {
    let (store, bot, server, _, host, box) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800), at = handedAt.addingTimeInterval(600)
    boxRound(box, job: name, reply: "Build is green.", at: at)
    bot.messages += [ChatMessage(role: .user, content: "[Cronjob \"\(name)\" output — scheduled job, not the user. Reply to it.]\nprompt", createdAt: at, metadata: [TurnKey.box: "1"]),
                     ChatMessage(role: .assistant, content: reply, createdAt: at.addingTimeInterval(5), metadata: [TurnKey.box: "2"], turnState: state)]
    server.add(jobPayload(id: "0000000abc18", name: name, schedule: "every 10m", lastRunAt: "2026-10-23T09:00:00+00:00"))
    server.set("0000000abc18", ["repeat": ["times": 3, "completed": 1]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "check the build", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc18", handedAt: handedAt))
    await store.reclaimHandoffs(); await store.reclaimHandoffs()
    return (store, bot, server, host)
}

@Test @MainActor func aRoundWhoseReplyInTheChatConflictsWithTheBoxKeepsTheRoutine() async throws {
    let (store, bot, server, host) = await staleRound(reply: "Build is red.", state: .incomplete)
    let automation = try #require(store.automations[bot.id])
    #expect(server.jobIDs == ["0000000abc18"] && !requestLines(host).contains { $0.hasPrefix("DELETE ") }, "kept, paused on the box")
    #expect(automation.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop) && automation.loop?.runs == 0)
    #expect(bot.messages.filter { $0.content == HandoffCopy.notReconciled(.loop) }.count == 1, "said once, tried again")
}

@Test @MainActor func aRoundWhoseFinishedReplyIsShorterThanTheBoxsKeepsTheRoutine() async throws {
    let (store, bot, server, host) = await staleRound(reply: "Build is", state: .finished)
    let automation = try #require(store.automations[bot.id])
    #expect(server.jobIDs == ["0000000abc18"] && !requestLines(host).contains { $0.hasPrefix("DELETE ") }, "a finished reply is never extended")
    #expect(automation.boxHandoff?.lastError == HandoffCopy.notReconciled(.loop) && automation.loop?.runs == 0)
    #expect(bot.messages.filter { $0.content == HandoffCopy.notReconciled(.loop) }.count == 1)
}

@Test @MainActor func aGoalWithRoundsMissingPastTheWaitIsHeldAndAStopEndsItOnTheBox() async throws {
    let (store, bot, server, _, _, box) = handoffStore()
    let name = AppStore.handoffName(.goal, chat: bot.id), handedAt = Date().addingTimeInterval(-3_600)
    server.add(jobPayload(id: "0000000abc19", name: name, schedule: "every 15m", lastRunAt: "2026-10-23T09:00:00+00:00"))
    server.set("0000000abc19", ["repeat": ["times": 4, "completed": 2]])
    store.automations[bot.id] = ChatAutomation(goal: GoalRun(text: "Write the release notes", maxRounds: 20, startedAt: Date(), maxDuration: 7200, codingEvidence: false),
                                               boxHandoff: BoxHandoff(kind: .goal, jobName: name, jobID: "0000000abc19", handedAt: handedAt))
    // Round 2's reply, which may hold the done block, is not in the session.
    boxRound(box, job: name, reply: "Drafted.", at: handedAt.addingTimeInterval(900))
    await store.reclaimHandoffs()
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc19"] && store.automations[bot.id]?.goal?.round == 0 && store.automations[bot.id]?.goal?.state == .running)
    #expect(store.automations[bot.id]?.boxHandoff?.lastError == HandoffCopy.roundsMissing(.goal) && bot.messages.last?.content == HandoffCopy.roundsMissing(.goal))
    store.stopAutomations(in: bot)
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && store.automations[bot.id]?.goal?.isActive != true, "stopped, not resumed")
}

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

/// A box with session history (`/v1/capabilities` says so) whose Bot Chat read answers with `status` and no rows.
private final class BoxSessionRead: @unchecked Sendable {
    private let lock = NSLock(); private var value = 503
    var status: Int { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

@MainActor private func handoffStore(botChat: Bool = true, sessionRead: BoxSessionRead? = nil) -> (AppStore, Bot, FakeJobsServer, Bodies, String) {
    let server = FakeJobsServer(), bodies = Bodies()
    let (host, session) = MockHermesProtocol.serve { request in
        if let sessionRead, let path = request.url?.path {
            if path.hasSuffix("/v1/capabilities") { return (200, ["features": ["session_chat_streaming": true]]) }
            if path.hasSuffix("/api/sessions/main-session/messages") {
                let status = sessionRead.status
                if status == 200 { return (200, ["object": "list", "data": [[String: Any]]()] as [String: Any]) }
                return (status, ["error": "unavailable"])
            }
        }
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
    return (store, bot, server, bodies, host)
}

/// What Hermes appends to the Bot Chat for a `bot-chat:` routine run, and the bot's reply.
@MainActor private func boxRound(_ bot: Bot, job: String, reply: String, at date: Date) {
    bot.messages.append(ChatMessage(role: .user, content: "[Cronjob \"\(job)\" output — scheduled job, not the user. Reply to it.]\nprompt", createdAt: date))
    bot.messages.append(ChatMessage(role: .assistant, content: reply, createdAt: date.addingTimeInterval(5)))
}

@Test @MainActor func aBotChatLoopRunsOnTheBoxWhileClosedAndComesBackWithoutRunningTwice() async throws {
    let (store, bot, server, bodies, host) = handoffStore()
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

    boxRound(bot, job: name, reply: "Build is green.", at: handoff.handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs()
    let lines = requestLines(host)
    let pause = try #require(lines.firstIndex(of: "POST /p/grok-jarvis/api/jobs/\(handoff.jobID!)/pause"))
    let delete = try #require(lines.firstIndex(of: "DELETE /p/grok-jarvis/api/jobs/\(handoff.jobID!)"))
    #expect(pause < delete && server.jobIDs.isEmpty, "paused before anything else, then deleted")
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(store.automations[bot.id]?.boxHandoff == nil && loop.runs == 1 && loop.timesLeft == 2 && loop.nextAt >= Date().addingTimeInterval(-5))
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(1) })
    #expect(bot.messages.first { CronDeliveryRow.jobName($0.content) == name }?.metadata[AutomationKey.display] == "Loop (on the box)")
}

@Test @MainActor func aGoalGetsAFifteenMinuteRoundWithinItsBudgetAndADoneReplyOnTheBoxEndsIt() async throws {
    let (store, bot, server, bodies, _) = handoffStore()
    store.automations[bot.id] = ChatAutomation(goal: GoalRun(text: "Write the release notes", maxRounds: 20, startedAt: Date(), maxDuration: 7200, codingEvidence: false))
    store.handOffForQuit(budget: 5)
    let body = try #require(bodies.all.first)
    #expect(body["schedule"] as? String == "every 15m" && [7, 8].contains(body["repeat"] as? Int ?? 0), "two hours of 15-minute rounds")
    #expect((body["prompt"] as? String)?.contains("Continue toward the goal: Write the release notes") == true)
    let handoff = try #require(store.automations[bot.id]?.boxHandoff)
    boxRound(bot, job: handoff.jobName, reply: "Drafted.", at: handoff.handedAt.addingTimeInterval(900))
    boxRound(bot, job: handoff.jobName, reply: """
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
    let (store, bot, _, bodies, _) = handoffStore(botChat: false)
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 300, timesLeft: nil, until: nil, nextAt: Date()))
    store.handOffForQuit(budget: 5)
    #expect(bodies.all.isEmpty && store.automations[bot.id]?.boxHandoff == nil)
    #expect(store.handoffPlans(now: Date()).isEmpty)
}

@Test @MainActor func anUnreachableBoxKeepsTheLoopAndARoutineTheQuitDidNotRecordIsFoundByName() async throws {
    let (store, bot, server, _, _) = handoffStore()
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
    let (store, bot, server, _, _) = handoffStore()
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
    let read = BoxSessionRead()
    let (store, bot, server, _, host) = handoffStore(sessionRead: read)
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc03", name: name, schedule: "every 10m"))
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc03", handedAt: handedAt))
    boxRound(bot, job: name, reply: "pong", at: handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs() // the read fails
    read.status = 200
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
    let (store, bot, server, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc04", name: name, schedule: "every 10m"))
    server.set("0000000abc04", ["repeat": ["times": 3, "completed": 2]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc04", handedAt: handedAt))
    boxRound(bot, job: name, reply: "first", at: handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs()
    #expect(server.job("0000000abc04")?["enabled"] as? Bool == false && store.automations[bot.id]?.boxHandoff?.waitingSince != nil,
            "paused; the second round's reply is not in the chat yet")
    #expect(store.automations[bot.id]?.loop?.runs == 0)
    boxRound(bot, job: name, reply: "second", at: handedAt.addingTimeInterval(1_200))
    await store.reclaimHandoffs()
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && loop.runs == 2 && loop.timesLeft == 1)
    #expect(bot.messages.contains { $0.content == HandoffCopy.loopRan(2) })
}

@Test @MainActor func aRoundWhoseReplyNeverArrivesStillCountsFromTheBoxAfterTheWait() async throws {
    let (store, bot, server, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc05", name: name, schedule: "every 10m"))
    server.set("0000000abc05", ["repeat": ["times": 3, "completed": 2]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc05", handedAt: handedAt))
    boxRound(bot, job: name, reply: "first", at: handedAt.addingTimeInterval(600))
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc05"] && store.automations[bot.id]?.boxHandoff != nil)
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    let loop = try #require(store.automations[bot.id]?.loop)
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil && loop.runs == 2 && loop.timesLeft == 1, "the box's count wins")
}

@Test @MainActor func aRunStillInFlightIsNeverDeletedWithinTheLongerWait() async throws {
    let (store, bot, server, _, _) = handoffStore()
    let name = AppStore.handoffName(.loop, chat: bot.id), handedAt = Date().addingTimeInterval(-1_800)
    server.add(jobPayload(id: "0000000abc06", name: name, schedule: "every 10m"))
    server.set("0000000abc06", ["fire_claim": ["by": "scheduler", "at": "2026-10-23T08:00:00+00:00"]])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()),
                                               boxHandoff: BoxHandoff(kind: .loop, jobName: name, jobID: "0000000abc06", handedAt: handedAt))
    await store.reclaimHandoffs()
    store.now = { Date().addingTimeInterval(AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    #expect(server.jobIDs == ["0000000abc06"] && store.automations[bot.id]?.boxHandoff != nil, "its round is not counted yet")
    store.now = { Date().addingTimeInterval(3 * AppStore.handoffSettle + 60) }
    await store.reclaimHandoffs()
    #expect(server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil)
}

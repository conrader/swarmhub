import Foundation
import Testing
@testable import AgentApp

// P46 1, 2, 5: the main chat titled "Bot Chat" once (a conflict asks), rows the box appends to it pulled in once and in
// order with "Woken by", `[SILENT]` exchanges hidden, and heartbeat runs never carded. Synthetic boxes only.

@MainActor @Test func theMainChatIsTitledBotChatOnce() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let start = Date()
    await store.pollLiveRowsOnce(now: start)
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(16))
    #expect(store.heartbeatSettings.botChats[bots[0].id.uuidString] == "s-jarvis" && states[0].with { $0.titles["s-jarvis"] } == "Bot Chat")
    #expect(requests(states[0], "PATCH", "/api/sessions").count == 1, "titled once")
    // A restart keeps it: no second PATCH.
    store.save()
    let reopened = AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: store.keyStore, defaults: store.defaults, hermesSession: store.hermesSession)
    let again = try #require(reopened.bots.first)
    #expect(reopened.hasBotChat(again))
    await reopened.pollLiveRowsOnce(now: start)
    #expect(requests(states[0], "PATCH", "/api/sessions").count == 1)
}

@MainActor @Test func anotherBotChatOfTheProfileAsksFirst() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0]
    states[0].add("cli-1", "user", "from the terminal")
    states[0].with { $0.titles["cli-1"] = "Bot Chat"; $0.sources["cli-1"] = "cli" }
    await store.pollLiveRowsOnce(now: Date())
    #expect(requests(states[0], "PATCH", "/api/sessions").isEmpty && store.botChatConflict(bot) == "cli-1")
    #expect(bot.messages.last?.content == BotChatCopy.conflict("Jarvis", profile: "grok-jarvis"))
    // The heartbeat refuses to start while the title is elsewhere, and the ask is not repeated.
    await store.heartbeatCommand("every 1h", bot: bot, conversation: bot).value
    #expect(bot.messages.filter { $0.content == BotChatCopy.conflict("Jarvis", profile: "grok-jarvis") }.count == 2, "the conflict line, then the command's answer")
    #expect(bot.messages.filter { $0.metadata[TurnKey.tone] == "warning" }.count == 1)
    // "Use this chat": the other one steps aside, then this chat takes the title.
    #expect(await store.useThisChatAsBotChat(bot) == nil)
    #expect(requests(states[0], "PATCH", "/api/sessions").map(\.path) == ["/api/sessions/cli-1", "/api/sessions/s-jarvis"])
    #expect(states[0].with { [$0.titles["cli-1"], $0.titles["s-jarvis"]] } == ["Bot Chat (earlier)", "Bot Chat"] && store.botChatConflict(bot) == nil)
}

@MainActor @Test func rowsTheBoxDeliversAreAddedOnceInOrderAndLabelled() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], box = states[0], start = Date()
    await store.pollLiveRowsOnce(now: start)
    #expect(bot.messages.count == 2, "the first read only records the session's size")
    deliverToBotChat(box, session: "s-jarvis", job: HeartbeatPlan.jobName, output: "Backup on box 2 failed.", reply: "The 09:00 backup failed: disk full.")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(5))
    #expect(bot.messages.count == 2, "not due yet: 15 s while nothing runs")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(15))
    #expect(bot.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    let woken = bot.messages[2]
    #expect(AutomationCopy.wokenBy(woken) == "Woken by: heartbeat" && woken.metadata[AutomationKey.display] == "Heartbeat")
    #expect(bot.messages[3].content == "The 09:00 backup failed: disk full." && !bot.messages[3].isSilentHeartbeat)
    #expect(bot.unreadCount == 1)
    // Nothing new: nothing added twice.
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(30))
    #expect(bot.messages.count == 4)

    // A routine's delivery, then a heartbeat the bot answered [SILENT].
    deliverToBotChat(box, session: "s-jarvis", job: "Digest", output: "3 new invoices", reply: "Three invoices came in; nothing urgent.")
    deliverToBotChat(box, session: "s-jarvis", job: HeartbeatPlan.jobName, output: "nothing open", reply: "[SILENT]")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(45))
    #expect(bot.messages.count == 8)
    #expect(AutomationCopy.wokenBy(bot.messages[4]) == "Woken by: routine Digest" && bot.messages[4].metadata[AutomationKey.display] == "Routine: Digest")
    #expect(bot.messages[6].isSilentHeartbeat && bot.messages[7].isSilentHeartbeat && !bot.messages[4].isSilentHeartbeat)
    #expect(bot.unreadCount == 2, "the silent reply counts nothing")
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil) == "Three invoices came in; nothing urgent.")
}

@MainActor @Test func rowsSwarmHubWroteAreNeverAddedAgain() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], start = Date()
    store.selectedBot = bot
    await store.pollLiveRowsOnce(now: start)
    states[0].with { $0.defaultScript = .reply(chunks: ["sure"]) }
    #expect(store.submitComposer(text: "one more thing"))
    try await waitUntil { !store.anyTurnRunning }
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(15))
    #expect(bot.messages.filter { $0.role != .system }.map(\.content) == ["hello", "hi there", "one more thing", "sure"])
}

@MainActor @Test func aRunningRoutineReadsEveryFiveSeconds() async throws {
    let (store, bots, states, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], start = Date()
    var running = jobPayload(id: "0000000a11ce", name: HeartbeatPlan.jobName); running["state"] = "running"; running["deliver"] = "bot-chat:grok-jarvis"
    tables[0].add(running)
    await store.refreshRoutines(for: bot)
    #expect(store.routineRunning(for: bot))
    await store.pollLiveRowsOnce(now: start)
    deliverToBotChat(states[0], session: "s-jarvis", job: HeartbeatPlan.jobName, output: "x", reply: "One thing needs you.")
    await store.pollLiveRowsOnce(now: start.addingTimeInterval(5))
    #expect(bot.messages.count == 4)
}

@MainActor @Test func heartbeatRunsPostNoCardAndSilentOnesShowInRoutines() async throws {
    let (store, bots, states, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], box = states[0]
    var heartbeat = jobPayload(id: "0000000a11ce", name: HeartbeatPlan.jobName, lastRunAt: "2026-10-15T08:07:00+00:00", lastStatus: "ok")
    heartbeat["deliver"] = "bot-chat:grok-jarvis"
    tables[0].add(heartbeat); tables[0].add(jobPayload(id: "00000000beef", name: "Digest", lastRunAt: "2026-10-15T08:00:00+00:00", lastStatus: "ok"))
    await store.refreshRoutines(for: bot)
    func cronRun(_ id: String, name: String, at started: Double, reply: String) {
        let session = "cron_\(id)_\(Int(started))"
        box.add(session, "user", "prompt", time: started); box.add(session, "assistant", reply, finish: "stop", time: started + 5)
        box.with { $0.sources[session] = "cron"; $0.titles[session] = "\(name) · Oct 15 10:07" }
    }
    cronRun("0000000a11ce", name: HeartbeatPlan.jobName, at: 1_792_055_220, reply: "[SILENT]")
    cronRun("00000000beef", name: "Digest", at: 1_792_055_000, reply: "Inbox digest")
    tables[0].set("0000000a11ce", ["last_run_at": "2026-10-15T09:07:05+00:00"])
    tables[0].set("00000000beef", ["last_run_at": "2026-10-15T09:03:25+00:00"])
    await store.refreshRoutines(for: bot)
    #expect(bot.messages.filter { $0.presentation == .routineResult }.map(\.content) == ["Inbox digest"], "the heartbeat posts no card")
    let job = try #require(store.heartbeatJob(for: bot))
    #expect(store.heartbeatLastResult(job, bot: bot) == "ok · silent")
    #expect(store.heartbeatSummary(for: bot)?.contains("last ok · silent") == true)
}

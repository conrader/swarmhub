import Foundation
import Testing
@testable import AgentApp

// P56: every Hermes turn says which routine is the bot's heartbeat (or that there is none), and a schedule changed on the
// box shows in Settings → Heartbeat with "Use the box's schedule" and "Put mine back". Synthetic boxes only.

private func instructions(_ state: SessionServer.State) -> [String] { state.chatPosts.map { $0.body?["instructions"] as? String ?? "" } }
private func inputs(_ state: SessionServer.State) -> [String] { state.chatPosts.map { $0.body?["input"] as? String ?? "" } }

@MainActor @Test func theTurnSaysThereIsNoHeartbeatOnlyOnceTheRoutinesWereRead() async throws {
    let (store, bots, states, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0]
    #expect(store.heartbeatContextLine(for: bot) == nil, "routines never read: unknown, not none")
    #expect(store.withHeartbeatContext(bot.persona, bot: bot) == bot.persona)
    await store.refreshRoutines(for: bot)
    let none = "No heartbeat is set; \(store.userName) can turn one on in SwarmHub."
    #expect(store.heartbeatContextLine(for: bot) == none)
    store.selectedBot = bot
    #expect(store.send(text: "do you have a heartbeat?"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(instructions(states[0]).last?.hasSuffix("\n\n" + none) == true, "with the other SwarmHub instructions")
    #expect(inputs(states[0]).last?.contains("heartbeat is set") == false, "never in the user's text")
}

@MainActor @Test func theTurnNamesAnAdoptedRoutineAndThenSwarmHubsPlan() async throws {
    let (store, bots, states, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], table = tables[0]
    var own = jobPayload(id: "00000000beef", name: "jarvis-hourly-heartbeat-cet", schedule: "0 7-22 * * *", prompt: "Check in")
    own["deliver"] = "bot-chat:grok-jarvis"; own["next_run_at"] = "2026-10-15T09:00:00+00:00"
    table.add(own)
    await store.refreshRoutines(for: bot)
    let user = store.userName, tail = "\(user) changes it in SwarmHub (Settings → Heartbeat, or /heartbeat every …)."
    #expect(store.heartbeatContextLine(for: bot) == "Your heartbeat: routine jarvis-hourly-heartbeat-cet, 0 7-22 * * *, next 11:00 (Europe/Warsaw). " + tail)
    await store.heartbeatCommand("every 1h 08:00-23:00", bot: bot, conversation: bot).value
    let line = "Your heartbeat: routine jarvis-hourly-heartbeat-cet, hourly 08–23, next 11:00 (Europe/Warsaw). " + tail
    #expect(store.heartbeatContextLine(for: bot) == line)
    store.selectedBot = bot
    #expect(store.send(text: "when do you wake up?"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(instructions(states[0]).last?.hasSuffix("\n\n" + line) == true && inputs(states[0]).last == "when do you wake up?")
    await store.heartbeatCommand("pause", bot: bot, conversation: bot).value
    #expect(store.heartbeatContextLine(for: bot) == "Your heartbeat: routine jarvis-hourly-heartbeat-cet, hourly 08–23, paused. " + tail)
}

@MainActor @Test func aScheduleChangedOnTheBoxIsShownAndEitherKeptOrPutBack() async throws {
    let (store, bots, _, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], table = tables[0]
    await store.heartbeatCommand("every 1h 08:00-23:00", bot: bot, conversation: bot).value
    let id = try #require(table.job(named: HeartbeatPlan.jobName)?["id"] as? String)
    let written = try #require(store.heartbeatSettings.schedules[bot.id.uuidString])
    #expect(store.heartbeatBoxChange(for: bot) == nil && store.heartbeatJob(for: bot)?.schedule == written)

    // The bot's cron tool edits the routine: the box's schedule is shown, nothing is written over it.
    let box = "0 7-20 * * *"
    table.set(id, ["schedule": ["kind": "cron", "expr": box, "display": box], "schedule_display": box])
    await store.refreshRoutines(for: bot)
    #expect(store.heartbeatBoxChange(for: bot) == box && store.heartbeatBoxChangeNotice(for: bot) == "changed on the box: 0 7-20 * * * (hourly 07–20)")
    #expect(store.heartbeatSummary(for: bot)?.hasPrefix("Heartbeat · hourly 07–20 · on") == true, "what runs, not the old plan")
    #expect(store.heartbeatContextLine(for: bot)?.hasPrefix("Your heartbeat: routine swarmhub-heartbeat, hourly 07–20,") == true)
    #expect(table.writes == ["POST swarmhub-heartbeat"])

    // Use the box's schedule: it becomes the plan (the box is +02:00 like the Mac), nothing is written.
    store.useBoxHeartbeatSchedule(bot)
    let adopted = store.heartbeatSettings.plan(for: bot.id)
    #expect(adopted.boxSchedule?.cron == box && adopted.label == "hourly 07–20" && adopted.interval == 3_600 && adopted.windowStart == 420 && adopted.windowEnd == 1_200)
    #expect(store.heartbeatBoxChange(for: bot) == nil && table.writes == ["POST swarmhub-heartbeat"])
    #expect(store.heartbeatContextLine(for: bot)?.hasPrefix("Your heartbeat: routine swarmhub-heartbeat, hourly 07–20,") == true)

    // Changed again, then Put mine back: the plan's cron goes back to the routine.
    let again = "15 10 * * *"
    table.set(id, ["schedule": ["kind": "cron", "expr": again, "display": again], "schedule_display": again])
    await store.refreshRoutines(for: bot)
    #expect(store.heartbeatBoxChange(for: bot) == again && store.heartbeatBoxChangeNotice(for: bot) == "changed on the box: 15 10 * * * (daily 10:15)")
    #expect(await store.putBackHeartbeatSchedule(bot) == nil)
    #expect(table.writes == ["POST swarmhub-heartbeat", "PATCH \(id) schedule"] && store.heartbeatJob(for: bot)?.schedule == box)
    #expect(store.heartbeatBoxChange(for: bot) == nil)

    // Editing the hours drops the adopted cron; Stop forgets what was written.
    var edited = adopted; edited.windowEnd = 22 * 60
    #expect(edited.boxSchedule == nil && edited.label == "hourly 07–22")
    _ = await store.stopHeartbeat(bot)
    #expect(store.heartbeatSettings.schedules.isEmpty && store.heartbeatSettings.plans.isEmpty)
}

@MainActor @Test func aPlanFromBeforeP56GetsItsBaselineAndOldStoresStillDecode() async throws {
    let (store, bots, _, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0]
    let plan = HeartbeatPlan(), cron = plan.cron(stagger: store.heartbeatStagger(for: bot), localOffset: 120, boxOffset: 120)
    var job = jobPayload(id: "0000000a11ce", name: HeartbeatPlan.jobName, schedule: cron); job["deliver"] = "bot-chat:grok-jarvis"
    tables[0].add(job)
    store.heartbeatSettings.plans[bot.id.uuidString] = plan
    await store.refreshRoutines(for: bot)
    #expect(store.heartbeatSettings.schedules[bot.id.uuidString] == cron && store.heartbeatBoxChange(for: bot) == nil)

    let old = #"{"template":{"interval":1800,"windowStart":480,"windowEnd":1380,"prompt":"p"},"plans":{"x":{"interval":3600,"prompt":"q"}},"botChats":{"x":"s"},"conflicts":{}}"#
    let decoded = try JSONDecoder().decode(HeartbeatSettings.self, from: Data(old.utf8))
    #expect(decoded.template.interval == 1_800 && decoded.plans["x"]?.prompt == "q" && decoded.plans["x"]?.boxSchedule == nil && decoded.botChats == ["x": "s"] && decoded.schedules.isEmpty)
}

@Test func adoptingABoxCronReadsItInMacTime() {
    let base = HeartbeatPlan()
    #expect(HeartbeatPlan.adopting("0 7-22 * * *", from: base, shift: 0).label == "hourly 07–22")
    #expect(HeartbeatPlan.adopting("7 6-21 * * *", from: base, shift: 120).label == "hourly 08–23")
    let night = HeartbeatPlan.adopting("12,42 0-6,22,23 * * *", from: base, shift: 0)
    #expect(night.label == "every 30 min 22–06" && night.windowStart == 22 * 60 && night.windowEnd == 6 * 60)
    #expect(HeartbeatPlan.adopting("5 * * * *", from: base, shift: 0).label == "hourly" && HeartbeatPlan.adopting("25 8 * * *", from: base, shift: 60).label == "daily 09:25")
    let odd = HeartbeatPlan.adopting("0 8,12,19 * * *", from: base, shift: 0)
    #expect(odd.label == "box schedule 0 8,12,19 * * *" && odd.cron(stagger: 33, localOffset: 0, boxOffset: 0) == "0 8,12,19 * * *" && odd.wakesPerDay() == 3)
}

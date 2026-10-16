import Foundation
import Testing
@testable import AgentApp

// P46: the heartbeat as one Hermes routine per bot (deliver bot-chat:<profile>): the plan and its cron, the stagger and the
// capacity cap, the command and its routine writes, adopting Jarvis's routine. Synthetic boxes only; no real network.

@Test func heartbeatPlanParsesAndBecomesBoxCron() throws {
    let plan = try HeartbeatPlan.parse("every 1h 08:00–23:00").get()
    #expect(plan.interval == 3_600 && plan.windowStart == 480 && plan.windowEnd == 1_380 && plan.prompt == HeartbeatPlan.defaultPrompt)
    #expect(plan.label == "hourly 08–23" && plan.wakesPerDay(stagger: 7) == 16)
    // Warsaw in October is UTC+2; a UTC box runs 08:07–23:07 local (the end hour included) as 06:07–21:07.
    #expect(plan.cron(stagger: 7, localOffset: 120, boxOffset: 0) == "7 6-21 * * *")
    #expect(plan.cron(stagger: 0, localOffset: 120, boxOffset: 120) == "0 8-23 * * *")
    let night = try HeartbeatPlan.parse("every 30 min 22:30-06:00 check the backups").get()
    #expect(night.prompt == "check the backups" && night.label == "every 30 min 22:30–06")
    #expect(night.cron(stagger: 12, localOffset: 0, boxOffset: 0) == "12,42 0-6,22,23 * * *")
    #expect(try HeartbeatPlan.parse("daily 09:00-10:00").get().cron(stagger: 25, localOffset: 60, boxOffset: 0) == "25 8 * * *")
    #expect(HeartbeatPlan.parse("soon") == .failure(.noInterval))
    #expect(try HeartbeatPlan.parse("every 1m").get().interval == 300, "at least five minutes")
    #expect(HeartbeatPlan.list([0, 1, 2, 5, 7, 8]) == "0-2,5,7,8")
}

@Test func staggerSpreadsBotsAndCapsEachBoxSlot() {
    let one = HeartbeatStagger.minute(for: "grok-jarvis")
    #expect(one == HeartbeatStagger.minute(for: "grok-jarvis") && (0..<60).contains(one))
    let profiles = (1...20).map { "bot-\($0)" }
    let capped = HeartbeatStagger.minutes(for: profiles, cap: 2)
    let perSlot = Dictionary(grouping: capped.values, by: { $0 / HeartbeatStagger.slot }).mapValues(\.count)
    #expect(capped.count == 20 && perSlot.values.allSatisfy { $0 <= 2 }, "two heartbeats at most in any five minutes")
    #expect(HeartbeatStagger.minutes(for: ["a", "b"], cap: 9) == ["a": HeartbeatStagger.minute(for: "a"), "b": HeartbeatStagger.minute(for: "b")])
    #expect(CronDeliveryRow.offsetMinutes("2026-10-15T09:00:00.123+02:00") == 120 && CronDeliveryRow.offsetMinutes("2026-10-15T09:00:00Z") == 0)
    #expect(CronDeliveryRow.offsetMinutes("2026-10-15T09:00:00-05:30") == -330 && CronDeliveryRow.offsetMinutes(nil) == nil)
    #expect(CronDeliveryRow.jobName("[Cronjob \"swarmhub-heartbeat\" output — scheduled job, not the user.]\nAll quiet") == "swarmhub-heartbeat")
    #expect(CronDeliveryRow.jobName("[Cronjob] hello") == nil && CronDeliveryRow.jobName("hello") == nil)
}

@MainActor @Test func theStaggerSharesTheBoxCapacity() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bots = (1...4).map { Bot(name: "B\($0)", backend: .hermes, hermesProfile: "p\($0)") }
    bots.forEach { $0.hermesBaseURL = "https://box.test/v1" }
    store.bots = bots
    let box = store.connection(of: bots[0])
    #expect(store.heartbeatCap(on: box) == 1, "a box never checked runs one at a time")
    store.boxReadings[box] = BoxReadings(capacity: BoxCapacityReport(cpus: 4, memTotalMB: 8_192, memAvailMB: 4_096, jobs: []))
    #expect(store.heartbeatCap(on: box) == BoxCapacity(BoxCapacityReport(cpus: 4, memTotalMB: 8_192, memAvailMB: 4_096, jobs: [])).advised)
    let minutes = bots.map(store.heartbeatStagger(for:))
    #expect(minutes == bots.map { HeartbeatStagger.minutes(for: ["p1", "p2", "p3", "p4"], cap: store.heartbeatCap(on: box))[store.profile(of: $0)]! })
}

@MainActor @Test func theCommandCreatesEditsPausesAndStopsTheRoutine() async throws {
    let (store, bots, states, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], table = tables[0]
    await store.heartbeatCommand("every 1h 08:00–23:00", bot: bot, conversation: bot).value
    let job = try #require(table.job(named: HeartbeatPlan.jobName))
    let minute = store.heartbeatStagger(for: bot)
    #expect(job["deliver"] as? String == "bot-chat:grok-jarvis" && job["prompt"] as? String == HeartbeatPlan.defaultPrompt)
    #expect((job["schedule"] as? [String: Any])?["expr"] as? String == HeartbeatPlan().cron(stagger: minute, localOffset: 120, boxOffset: 0))
    #expect(bot.messages.last?.content.hasPrefix("Heartbeat on for Jarvis: hourly 08–23.") == true)
    #expect(states[0].with { $0.titles["s-jarvis"] } == "Bot Chat", "the Bot Chat is titled before the routine is made")

    await store.heartbeatCommand("every 2h 09:00-18:00 anything urgent?", bot: bot, conversation: bot).value
    let id = try #require(job["id"] as? String)
    #expect(table.writes == ["POST swarmhub-heartbeat", "PATCH \(id) prompt,schedule"])
    #expect(bot.messages.last?.content.hasPrefix("Heartbeat updated for Jarvis: every 2 h 09–18.") == true)
    await store.heartbeatCommand("pause", bot: bot, conversation: bot).value
    #expect(bot.messages.last?.content == "Heartbeat paused." && store.heartbeatJob(for: bot)?.isPaused == true)
    await store.heartbeatCommand("status", bot: bot, conversation: bot).value
    #expect(bot.messages.last?.content.hasPrefix("Heartbeat · every 2 h 09–18 · paused") == true)
    await store.heartbeatCommand("resume", bot: bot, conversation: bot).value
    await store.heartbeatCommand("stop", bot: bot, conversation: bot).value
    #expect(table.writes.suffix(3) == ["pause \(id)", "resume \(id)", "DELETE \(id)"])
    #expect(bot.messages.last?.content == "Heartbeat stopped." && store.heartbeatJob(for: bot) == nil && store.heartbeatSettings.plans.isEmpty)
    await store.heartbeatCommand("soon", bot: bot, conversation: bot).value
    #expect(bot.messages.last?.content == HeartbeatCopy.usage && states[0].chatPosts.isEmpty, "the app never sends a heartbeat turn")
}

@MainActor @Test func jarvissOwnHeartbeatRoutineIsAdoptedNotDuplicated() async throws {
    let (store, bots, _, tables) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0], table = tables[0]
    var own = jobPayload(id: "00000000beef", name: "jarvis-hourly-heartbeat-cet", schedule: "0 7-22 * * *", prompt: "Check in")
    own["deliver"] = "bot-chat:grok-jarvis"; own["next_run_at"] = "2026-10-15T09:00:00+00:00"
    table.add(own); table.add(jobPayload(id: "00000000cafe", name: "Morning brief"))
    await store.heartbeatCommand("every 1h 08:00-23:00", bot: bot, conversation: bot).value
    #expect(table.writes == ["PATCH 00000000beef prompt,schedule"], "no second routine")
    #expect(table.jobs.count == 2 && store.heartbeatJob(for: bot)?.id == "00000000beef")
    #expect(bot.messages.last?.content.hasPrefix("Heartbeat updated for Jarvis") == true)
    await store.heartbeatCommand("stop", bot: bot, conversation: bot).value
    #expect(table.writes.last == "pause 00000000beef" && table.jobs.count == 2, "Jarvis's own routine is paused, never deleted")
    #expect(bot.messages.last?.content.contains("paused, not deleted") == true)
}

@MainActor @Test func applyToAllSetsEveryBotInOneBatchWithOverrides() async throws {
    let (store, bots, _, tables) = heartbeatStore(bots: ["Jarvis", "Infra", "Reactor"])
    var custom = HeartbeatPlan(); custom.interval = 7_200; custom.prompt = "Disks and backups only."
    store.heartbeatSettings.plans[bots[1].id.uuidString] = custom
    store.heartbeatSettings.template.windowStart = 9 * 60
    let problems = await store.applyHeartbeats(nil, to: bots)
    #expect(problems.isEmpty && store.heartbeatBatch.summary == "Heartbeat set for 3 bots.")
    #expect(tables.map(\.writes) == Array(repeating: ["POST swarmhub-heartbeat"], count: 3), "one create per bot, nothing else")
    #expect(tables[1].jobs.first?["prompt"] as? String == "Disks and backups only." && tables[0].jobs.first?["prompt"] as? String == HeartbeatPlan.defaultPrompt)
    #expect(store.heartbeatSettings.plans.count == 3 && store.heartbeatSettings.plan(for: bots[0].id).windowStart == 540)
    // A bot without a main chat yet is named, the others still applied.
    let fresh = Bot(name: "Fresh", backend: .hermes, hermesProfile: "grok-fresh"); store.bots.append(fresh)
    let second = await store.applyHeartbeats(store.heartbeatSettings.template, to: [bots[0], fresh])
    #expect(second.keys.map { $0 } == [fresh.id] && store.heartbeatBatch.summary == "Not set for Fresh; see each row.")
}

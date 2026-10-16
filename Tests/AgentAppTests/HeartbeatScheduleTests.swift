import Foundation
import Testing
@testable import AgentApp

// P46 follow-up: one wake count everywhere (the generated cron's fire times), the next run inside the active hours, and the
// chat's heartbeat bar without empty parts. Pure or synthetic; no box.

private let plans = [HeartbeatPlan(), HeartbeatPlan(interval: 7_200, windowStart: 7 * 60, windowEnd: 19 * 60),
                     HeartbeatPlan(interval: 1_800, windowStart: 22 * 60 + 30, windowEnd: 6 * 60), HeartbeatPlan(interval: 900, windowStart: nil, windowEnd: nil),
                     HeartbeatPlan(interval: 10_800, windowStart: 8 * 60, windowEnd: 23 * 60), HeartbeatPlan(interval: 86_400, windowStart: 9 * 60, windowEnd: 10 * 60)]

/// The times the cron fires in one box day, counted by walking `nextFire`.
private func firesInADay(_ cron: String, box: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = box
    let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_792_051_200)), end = start.addingTimeInterval(86_400)
    var count = 0, cursor = start.addingTimeInterval(-1)
    while let next = HeartbeatPlan.nextFire(cron, after: cursor, boxZone: box), next < end { count += 1; cursor = next }
    return count
}

@MainActor @Test func theTemplateAndABotRowWithTheSamePlanShowTheCronsWakeCount() {
    let (store, bots, _, _) = heartbeatStore(bots: ["Jarvis", "Infra"])
    #expect(HeartbeatPlan().wakesPerDay() == 16, "hourly 08–23: 08:xx through 23:xx")
    #expect(plans[1].wakesPerDay() == 7, "every 2 h 07–19: 07, 09, … 19")
    for plan in plans {
        for bot in bots {
            let stagger = store.heartbeatStagger(for: bot)
            #expect(plan.wakesPerDay() == plan.wakesPerDay(stagger: stagger), "template = bot row for \(plan.label)")
            #expect(HeartbeatCopy.turns(plan.wakesPerDay()) == HeartbeatCopy.turns(plan.wakesPerDay(stagger: stagger)))
            for box in [0, -300, 120, 540] {
                let cron = plan.cron(stagger: stagger, localOffset: store.heartbeatLocalOffset, boxOffset: box)
                #expect(firesInADay(cron, box: TimeZone(secondsFromGMT: box * 60)!) == plan.wakesPerDay(stagger: stagger), "\(plan.label) as \(cron)")
            }
        }
    }
}

@Test func theNextRunIsAlwaysInsideTheActiveHours() {
    let mac = TimeZone(secondsFromGMT: 120 * 60)!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = mac
    let start = Date(timeIntervalSince1970: 1_792_094_400) // 2026-10-15 20:00 UTC, 22:00 on the Mac: the next 48 h cross two midnights
    for plan in plans {
        for stagger in [0, 7, 59] {
            for box in [0, -300, 120, 540] {
                let zone = TimeZone(secondsFromGMT: box * 60)!, cron = plan.cron(stagger: stagger, localOffset: 120, boxOffset: box)
                for step in stride(from: 0, to: 48 * 3_600, by: 1_500) {
                    let now = start.addingTimeInterval(TimeInterval(step))
                    guard let next = HeartbeatPlan.nextFire(cron, after: now, boxZone: zone) else { Issue.record("no next run for \(cron)"); return }
                    let parts = calendar.dateComponents([.hour, .minute], from: next)
                    #expect(plan.inWindow(minute: parts.hour! * 60 + parts.minute!), "\(plan.label) stagger \(stagger) box \(box): \(next)")
                    #expect(next > now && next.timeIntervalSince(now) <= 86_400)
                }
            }
        }
    }
    // Jarvis at 23:30 and 00:57 on the Mac (a UTC box): next is 08:07, not after midnight.
    let cron = HeartbeatPlan().cron(stagger: 7, localOffset: 120, boxOffset: 0)
    for late in [start.addingTimeInterval(5_400), start.addingTimeInterval(10_620)] {
        let next = try! #require(HeartbeatPlan.nextFire(cron, after: late, boxZone: TimeZone(secondsFromGMT: 0)!))
        #expect(calendar.dateComponents([.hour, .minute], from: next) == DateComponents(hour: 8, minute: 7))
    }
}

@MainActor @Test func theHeartbeatBarHasNoEmptyParts() {
    let (store, bots, _, _) = heartbeatStore(bots: ["Jarvis"])
    let bot = bots[0]
    store.heartbeatSettings.plans[bot.id.uuidString] = HeartbeatPlan()
    let job = HeadlessP46Shots.heartbeatJob(profile: "grok-jarvis", schedule: "7 6-21 * * *", now: store.now())
    store.routines.update(bot.id) { $0.jobs = .loaded([job]) }
    #expect(job.lastRunAt == nil)
    #expect(store.heartbeatBar(job, bot: bot) == "Heartbeat · hourly 08–23 · next 10:07", "08:00 UTC is 10:00 in Warsaw; the UTC box fires at 08:07")
    #expect(store.heartbeatSummary(for: bot) == "Heartbeat · hourly 08–23 · on · next 10:07")
    store.heartbeatSettings.plans = [:]
    var bare = job; bare.scheduleDisplay = ""; bare.nextRunAt = nil
    #expect(store.heartbeatBar(bare, bot: bot) == "Heartbeat · on")
    #expect(ChipText.line(["Heartbeat", "", nil, "  ", "next 10:07"]) == "Heartbeat · next 10:07")
}

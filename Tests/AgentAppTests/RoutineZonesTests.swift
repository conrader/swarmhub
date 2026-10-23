import Foundation
import Testing
@testable import AgentApp

// recsfix1 (#13): a once-a-day cron moved between the Mac's zone and the box's, at the offsets of its next run.

private let warsaw = TimeZone(identifier: "Europe/Warsaw")!, utc = TimeZone(identifier: "UTC")!
private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func job(next: String?, last: String? = nil) -> HermesJob {
    var row: [String: Any] = ["id": "a1", "name": "x", "schedule": ["kind": "cron", "expr": "0 9 * * *"]]
    if let next { row["next_run_at"] = next }
    if let last { row["last_run_at"] = last }
    return HermesJob.parse(row)!
}

@Test func aDailyTimeMovesByTheZonesDifferenceInSummerAndWinter() {
    let summer = RoutineZones(local: warsaw, box: utc, now: at(10, 21)), winter = RoutineZones(local: warsaw, box: utc, now: at(11, 18))
    #expect(summer.boxSchedule("0 9 * * 1-5") == "0 7 * * 1-5" && winter.boxSchedule("0 9 * * 1-5") == "0 8 * * 1-5")
    #expect(summer.boxSchedule("30 7 * * mon-fri") == "30 5 * * mon-fri", "days written as names stay as written")
    #expect(summer.localSchedule("0 7 * * 1-5") == "0 9 * * 1-5" && winter.localSchedule("0 8 * * 1-5") == "0 9 * * 1-5")
    #expect(summer.shift("0 9 * * 1-5") == 120 && winter.shift("0 9 * * 1-5") == 60)
    let same = RoutineZones(local: warsaw, box: warsaw, now: at(10, 21))
    #expect(same.isSame && same.boxSchedule("0 9 * * 1-5") == "0 9 * * 1-5")
    for other in ["*/15 * * * *", "every 2h", "0 9 1 * *", "0 9,18 * * *"] { #expect(summer.boxSchedule(other) == other, "\(other): not a daily time") }
}

/// DST edges: the offset is the next run's, not today's. Autumn: offered Saturday 24 October (UTC+2), first weekday run
/// Monday 26 October after summer time ends (UTC+1). Spring: offered Friday 27 March (UTC+1), first run Monday 30 March
/// (UTC+2). A daily routine offered on Saturday 24 October first runs on Sunday 25 October, already UTC+1.
@Test func aDSTChangeBeforeTheFirstRunUsesThatRunsOffset() {
    #expect(RoutineZones(local: warsaw, box: utc, now: at(10, 24)).boxSchedule("0 9 * * 1-5") == "0 8 * * 1-5")
    #expect(RoutineZones(local: warsaw, box: utc, now: at(3, 27)).boxSchedule("0 9 * * 1-5") == "0 7 * * 1-5")
    #expect(RoutineZones(local: warsaw, box: utc, now: at(10, 24)).boxSchedule("0 9 * * *") == "0 8 * * *")
    #expect(RoutineZones(local: warsaw, box: utc, now: at(10, 24, 5)).boxSchedule("0 9 * * 6") == "0 7 * * 6", "still today, still summer time")
}

@Test func aTimeThatCrossesMidnightMovesItsDays() {
    let summer = RoutineZones(local: warsaw, box: utc, now: at(10, 21))
    #expect(summer.boxSchedule("30 0 * * 1-5") == "30 22 * * 0-4", "Monday 00:30 in Warsaw is Sunday 22:30 UTC")
    #expect(summer.localSchedule("30 22 * * 0-4") == "30 0 * * 1-5")
    #expect(summer.boxSchedule("0 1 * * 0,6") == "0 23 * * 5,6")
    let east = RoutineZones(local: newYork, box: utc, now: at(10, 21))
    #expect(east.boxSchedule("0 21 * * 1-5") == "0 1 * * 2-6" && east.shift("0 21 * * 1-5") == -240)
    #expect(east.boxSchedule("0 21 * * *") == "0 1 * * *")
}

@Test func theBoxZoneComesFromATimeItsJobsReported() {
    #expect(RoutineZones.boxZone([], local: warsaw).secondsFromGMT() == 0, "no job says: UTC")
    #expect(RoutineZones.boxZone([job(next: nil)], local: warsaw).secondsFromGMT() == 0)
    #expect(RoutineZones.boxZone([job(next: "2026-10-22T09:00:00.000001+00:00")], local: warsaw).secondsFromGMT() == 0)
    #expect(RoutineZones.boxZone([job(next: nil, last: "2026-10-21T09:00:00Z")], local: warsaw).secondsFromGMT() == 0)
    let same = RoutineZones.boxZone([job(next: "2026-10-22T09:00:00+02:00")], local: warsaw)
    #expect(same.identifier == warsaw.identifier, "the Mac's own offset then: the box keeps the user's zone, DST and all")
    let india = RoutineZones.boxZone([job(next: "2026-10-22T09:00:00+05:30")], local: warsaw)
    #expect(india.secondsFromGMT() == 19_800 && RoutineZones(local: warsaw, box: india, now: at(10, 21)).boxName == "UTC+05:30")
    #expect(RoutineZones(local: warsaw, box: utc, now: at(10, 21)).boxName == "UTC")
}

@Test func theLeadSaysBothTimesAndHowTheClocksDiffer() {
    let draft = RoutineDraft(botID: UUID(), name: "Inbox", schedule: "0 9 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 9)
    let lead = BotSuggestionCopy.lead(question: "Q?", draft: draft, zones: RoutineZones(local: warsaw, box: utc, now: at(10, 21)))
    #expect(lead.contains("schedule `0 7 * * 1-5` (cron in your time zone UTC: that is 9:00 in my time zone Europe/Warsaw)"))
    #expect(lead.contains("with deliver 'local'") && lead.contains("My clock is 2 h ahead of yours, so a time I name is 2 h earlier in your cron."))
    #expect(lead.contains("When you tell me a time, say it in my time zone") && lead.contains("schedule `<cron in your time zone>`"))
    var told = draft; told.boxSchedule = "15 7 * * 1-5"
    #expect(BotSuggestionCopy.lead(question: "Q?", draft: told, zones: RoutineZones(local: warsaw, box: utc, now: at(10, 21))).contains("`15 7 * * 1-5`"))
    let same = BotSuggestionCopy.lead(question: "Q?", draft: draft, zones: RoutineZones(local: warsaw, box: warsaw, now: at(10, 21)))
    #expect(same.contains("`0 9 * * 1-5` (cron, 9:00 in my time zone Europe/Warsaw, which your cron runs in too)") && !same.contains("My clock"))
    #expect(BotSuggestionCopy.difference(-330, zones: RoutineZones(local: utc, box: TimeZone(secondsFromGMT: 19_800)!, now: at(10, 21)))
            == " My clock is 5 h 30 min behind yours, so a time I name is 5 h 30 min later in your cron.")
}

/// The bot's `Routine:` line is in the box's time: read back in the Mac's for what the user is shown, kept as told.
@Test func theBotsRoutineLineIsReadInTheBoxsTime() {
    let zones = RoutineZones(local: warsaw, box: utc, now: at(10, 21))
    let draft = RoutineDraft(botID: UUID(), name: "Inbox", schedule: "0 9 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 9)
    let offer = draft.adjusted(byBot: "**Routine:** name \"Inbox digest\", schedule `30 5 * * 1,3,5`, prompt \"Summarize my inbox\"", zones: zones)
    #expect(offer.schedule == "30 7 * * 1,3,5" && offer.boxSchedule == "30 5 * * 1,3,5" && offer.when == "every Monday, Wednesday and Friday at 7:30")
    let moved = offer.adjusted(by: "make it 8:00")
    #expect(moved.schedule == "0 8 * * 1,3,5" && moved.boxSchedule == nil, "another time: converted again before the bot is told")
    #expect(offer.adjusted(by: "Yes, at 7:30") == offer, "the same time keeps what the bot was told")
}

/// The ledger 0.6.5 wrote (no `boxSchedule`) still reads.
@Test func aDraftFrom065Decodes() throws {
    let old = #"{"id":"8D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","botID":"1D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","name":"Inbox","schedule":"0 9 * * 1-5","prompt":"p","weekdaysOnly":true,"hour":9}"#
    let draft = try JSONDecoder().decode(RoutineDraft.self, from: Data(old.utf8))
    #expect(draft.schedule == "0 9 * * 1-5" && draft.boxSchedule == nil)
}

/// The editor a yes falls back to writes the box's time: the routine converted with the zone read now.
@MainActor @Test func theFallbackEditorGetsTheBoxsSchedule() {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.heartbeatTimeZone = warsaw; store.now = { at(10, 21) }
    let hermes = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), local = Bot(name: "Ada")
    store.bots = [hermes, local]
    #expect(store.suggestionZones(for: hermes).boxSchedule("0 9 * * 1-5") == "0 7 * * 1-5", "no jobs read: UTC")
    #expect(store.suggestionZones(for: local).isSame, "a bot whose routines run on this Mac")
}

/// recsfix2: the box's cron has no daylight saving time where the Mac's has: the zones drift, the editor's note says so,
/// and a 0.6.5 ledger record (no job recorded) still decodes.
@Test func aUTCBoxDriftsFromWarsawAndTheEditorSaysSo() throws {
    let drifting = RoutineZones(local: warsaw, box: utc, now: at(10, 21)), same = RoutineZones(local: warsaw, box: warsaw, now: at(10, 21))
    let fixed = RoutineZones(local: utc, box: TimeZone(secondsFromGMT: 3_600)!, now: at(10, 21))
    #expect(drifting.drifts && !same.drifts && !fixed.drifts)
    #expect(InspectorCopy.scheduleSummary("Weekdays at 9:00", zones: drifting) == "Weekdays at 9:00 · times use your box's time zone, UTC, which does not change with your daylight saving time")
    #expect(InspectorCopy.scheduleSummary("Weekdays at 9:00", zones: fixed) == "Weekdays at 9:00 · times use your box's time zone, UTC+01:00")
    #expect(InspectorCopy.scheduleSummary("Weekdays at 9:00", zones: same) == InspectorCopy.scheduleSummary("Weekdays at 9:00"))
    #expect(BotSuggestionCopy.drift(drifting, app: "Swarm Hub").contains("Swarm Hub moves this routine's hour") && BotSuggestionCopy.drift(same, app: "Swarm Hub").isEmpty)
    let old = #"{"records":[{"id":"8D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","botID":"1D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","stems":["inbox"],"example":"x","#
        + #""askedAt":0,"state":"accepted","messageID":"2D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","draft":{"id":"8D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","#
        + #""botID":"1D3E3F57-3B5C-4C6E-9D57-0D7E1F2A3B4C","name":"Inbox","schedule":"0 9 * * 1-5","prompt":"p","weekdaysOnly":true,"hour":9}}],"posted":[]}"#
    let ledger = try JSONDecoder().decode(BotSuggestionLedger.self, from: Data(old.utf8))
    #expect(ledger.records.first?.jobID == nil && ledger.records.first?.letGo == nil)
}

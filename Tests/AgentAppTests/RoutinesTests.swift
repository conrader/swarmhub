import Foundation
import Testing
@testable import AgentApp

@MainActor @Test func jobsRequestShapesUseProfilePrefixAndProfileKey() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "0123456789ab", name: "Morning brief"))
    let (store, bot, host) = routinesStore(server)

    #expect(await store.refreshRoutines(for: bot))
    #expect(store.routines.state(for: bot.id).jobs.value?.map(\.name) == ["Morning brief"])

    #expect(await store.createRoutine(for: bot, name: "Tide check", schedule: "30 7 * * 1-5", prompt: "Check the tides") == nil)
    let created = try #require(store.routines.state(for: bot.id).jobs.value?.first { $0.name == "Tide check" })
    let createRequest = try #require(MockHermesProtocol.recorded(host).last)
    #expect(jsonBody(createRequest) as NSDictionary? == ["name": "Tide check", "schedule": "30 7 * * 1-5", "prompt": "Check the tides", "deliver": "local"] as NSDictionary)

    #expect(await store.updateRoutine(created, for: bot, name: "Tide check", schedule: "0 8 * * 1-5", prompt: "Check the tides") == nil)
    let patch = try #require(MockHermesProtocol.recorded(host).last)
    #expect(jsonBody(patch) as NSDictionary? == ["schedule": "0 8 * * 1-5"] as NSDictionary, "only changed fields are sent")
    #expect(store.routines.state(for: bot.id).jobs.value?.first { $0.id == created.id }?.schedule == "0 8 * * 1-5")

    await store.setRoutine(created, enabled: false, for: bot)
    #expect(store.routines.state(for: bot.id).jobs.value?.first { $0.id == created.id }?.isPaused == true)
    await store.setRoutine(created, enabled: true, for: bot)
    await store.runRoutineNow(created, for: bot)
    await store.deleteRoutine(created, for: bot)
    #expect(server.job(created.id) == nil)
    #expect(store.routines.state(for: bot.id).jobs.value?.map(\.name) == ["Morning brief"])

    let id = created.id
    #expect(requestLines(host) == [
        "GET /p/grok-jarvis/api/jobs?include_disabled=true",
        "POST /p/grok-jarvis/api/jobs",
        "PATCH /p/grok-jarvis/api/jobs/\(id)",
        "POST /p/grok-jarvis/api/jobs/\(id)/pause",
        "POST /p/grok-jarvis/api/jobs/\(id)/resume",
        "POST /p/grok-jarvis/api/jobs/\(id)/run",
        "DELETE /p/grok-jarvis/api/jobs/\(id)",
    ])
    #expect(MockHermesProtocol.recorded(host).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer jarvis-key" })
    #expect(store.routines.state(for: bot.id).error == nil)
}

@MainActor @Test func missingJobsAPITurnsTheFeatureOff() async {
    let server = FakeJobsServer(); server.listStatus = 404
    let (store, bot, host) = routinesStore(server)
    bot.routines = [.init(name: "Old local", schedule: "Weekdays at 8:30")]
    let now = Date()
    await store.pollRoutinesOnce(now: now)
    #expect(store.routines.state(for: bot.id).jobs == .unavailable("This Hermes server has no jobs API."))
    #expect(!store.routines.state(for: bot.id).hasJobsAPI)
    await store.pollRoutinesOnce(now: now.addingTimeInterval(3600))
    #expect(requestLines(host) == ["GET /p/grok-jarvis/api/jobs?include_disabled=true"], "the inbox skips a server without the jobs API")
    #expect(bot.routines.count == 1, "the local list stays as it was")
}

@MainActor @Test func schedulerUnavailableIsReadableAndNotDuplicated() async {
    let server = FakeJobsServer(); server.createStatus = 424
    let (store, bot, host) = routinesStore(server)
    let error = await store.createRoutine(for: bot, name: "Ledger", schedule: "every 2h", prompt: "Reconcile")
    #expect(error?.contains("scheduler is unavailable") == true && error?.contains("Don't create it again") == true)
    #expect(store.routines.state(for: bot.id).error == error)
    // The saved job is listed (fetched again), not created twice.
    #expect(server.jobIDs.count == 1)
    #expect(store.routines.state(for: bot.id).jobs.value?.map(\.name) == ["Ledger"])
    #expect(requestLines(host) == ["POST /p/grok-jarvis/api/jobs", "GET /p/grok-jarvis/api/jobs?include_disabled=true"])
}

@MainActor @Test func inboxPostsOneCardPerRunAcrossPollsAndRestore() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "00000000beef", name: "Morning brief", lastRunAt: "2026-10-12T09:00:04.512345+02:00", lastStatus: "ok"))
    let url = temporaryStore()
    let (store, bot, host) = routinesStore(server, url: url)
    var now = Date()

    // First sighting: an old run is only recorded, never carded.
    await store.pollRoutinesOnce(now: now)
    #expect(bot.messages.isEmpty && bot.unreadCount == 0)
    #expect(bot.routineRunMarks == ["00000000beef": "2026-10-12T09:00:04.512345+02:00"])

    let longReply = "Inbox: " + String(repeating: "x", count: 700)
    server.finishRun("00000000beef", at: "2026-10-13T09:00:06.000001+02:00", sessionStarted: 1_791_874_800, reply: longReply)
    await store.pollRoutinesOnce(now: now.addingTimeInterval(30))
    #expect(bot.messages.isEmpty, "polls are at least 60 s apart")
    now.addTimeInterval(61); await store.pollRoutinesOnce(now: now)
    let card = try #require(bot.messages.last)
    #expect(bot.messages.count == 1 && bot.unreadCount == 1)
    #expect(card.presentation == .routineResult && card.role == .assistant)
    #expect(card.metadata["routine"] == "Morning brief" && card.metadata["status"] == "ok" && card.metadata["sessionID"] == "cron_00000000beef_1791874800")
    #expect(card.content.count == 601 && card.content.hasPrefix("Inbox: x") && card.content.hasSuffix("…"))
    #expect(requestLines(host).suffix(2) == ["GET /p/grok-jarvis/api/sessions?source=cron&limit=50&offset=0",
                                             "GET /p/grok-jarvis/api/sessions/cron_00000000beef_1791874800/messages?order=latest&limit=50"])

    now.addTimeInterval(61); await store.pollRoutinesOnce(now: now)
    #expect(bot.messages.count == 1 && bot.unreadCount == 1, "the same run is never carded twice")

    // A restored store remembers the run it already carded.
    let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: store.keyStore, defaults: store.defaults, hermesSession: store.hermesSession)
    let restoredBot = try #require(restored.bots.first)
    #expect(restoredBot.routineRunMarks["00000000beef"] == "2026-10-13T09:00:06.000001+02:00")
    await restored.pollRoutinesOnce(now: now.addingTimeInterval(61))
    #expect(restoredBot.messages.count == 1)

    server.finishRun("00000000beef", at: "2026-10-14T09:00:02+02:00", sessionStarted: 1_791_961_200, reply: "", status: "error", error: "Provider timed out")
    await restored.pollRoutinesOnce(now: now.addingTimeInterval(122))
    let failure = try #require(restoredBot.messages.last)
    #expect(restoredBot.messages.count == 2 && restoredBot.unreadCount == 2)
    #expect(failure.metadata["status"] == "error" && failure.metadata["error"] == "Provider timed out" && failure.content.isEmpty)
}

@MainActor @Test func importedRoutineIsCreatedPausedOnlyOnRequest() async throws {
    let server = FakeJobsServer()
    let (store, _, host) = routinesStore(server)
    let manifest = try GrokTemplateParser.parse(#"{"name":"Fixture","routines":[{"name":"Nightly","prompt":"Do it","schedule":"0 1 * * *"}]}"#.data(using: .utf8)!)
    let bot = store.importTemplate(TemplateImportMapper.makePlan(from: manifest, hermesProfile: "grok-jarvis"))
    #expect(bot.hermesProfile == "grok-jarvis" && bot.backend == .hermes)
    let routine = try #require(bot.routines.first)
    #expect(!routine.isEnabled && routine.importKind == .cron)
    #expect(MockHermesProtocol.recorded(host).isEmpty, "importing never touches the server")

    await store.refreshRoutines(for: bot)
    #expect(await store.createRoutineOnServer(routine, for: bot) == nil)
    let id = try #require(server.jobIDs.first)
    #expect(server.job(id)?["enabled"] as? Bool == false)
    #expect(requestLines(host).suffix(2) == ["POST /p/grok-jarvis/api/jobs", "POST /p/grok-jarvis/api/jobs/\(id)/pause"])
    #expect(bot.routines.isEmpty)
    #expect(store.routines.state(for: bot.id).jobs.value?.first?.isPaused == true)
    #expect(bot.routineRunMarks[id] == "", "its first run will be carded")

    // If the pause fails, the new job is removed again and the routine stays local.
    server.pauseStatus = 500
    let second = BotRoutine(name: "Weekly", schedule: "0 9 * * 1", prompt: "Plan", isEnabled: false, importKind: .cron)
    bot.routines = [second]
    #expect(await store.createRoutineOnServer(second, for: bot) != nil)
    #expect(server.jobIDs == [id])
    #expect(requestLines(host).last?.hasPrefix("DELETE /p/grok-jarvis/api/jobs/") == true)
    #expect(bot.routines.map(\.name) == ["Weekly"])
}

@MainActor @Test func runNowOnPausedRoutinePausesItAgainAfterTheRun() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "0000000000aa", name: "Digest", enabled: false))
    let (store, bot, host) = routinesStore(server)
    await store.refreshRoutines(for: bot)
    let job = try #require(store.routines.state(for: bot.id).jobs.value?.first)
    await store.runRoutineNow(job, for: bot)
    #expect(server.job(job.id)?["enabled"] as? Bool == true, "Hermes re-enables a job it runs")
    server.finishRun(job.id, at: "2026-10-13T10:00:00+02:00", sessionStarted: 1_791_878_000, reply: "Done")
    await store.refreshRoutines(for: bot)
    #expect(server.job(job.id)?["enabled"] as? Bool == false)
    #expect(bot.messages.last?.content == "Done")
    #expect(requestLines(host).contains("POST /p/grok-jarvis/api/jobs/\(job.id)/pause"))
}

@Test func schedulePresetsRoundTripAndDescribe() {
    var draft = RoutineScheduleDraft(); draft.hour = 7; draft.minute = 5
    #expect(draft.expression == "5 7 * * *")
    draft.preset = .weekdays; #expect(draft.expression == "5 7 * * 1-5")
    draft.preset = .weekly; draft.weekday = 0; #expect(draft.expression == "5 7 * * 0")
    draft.preset = .everyHours; #expect(draft.expression == "0 * * * *")
    draft.preset = .custom; draft.custom = " every 30m "; #expect(draft.expression == "every 30m")
    #expect(RoutineScheduleDraft(parsing: "30 8 * * 1-5") == { var d = RoutineScheduleDraft(); d.preset = .weekdays; d.hour = 8; d.minute = 30; d.custom = "30 8 * * 1-5"; return d }())
    #expect(RoutineScheduleDraft(parsing: "0 9 * * 7").weekday == 0)
    #expect(RoutineScheduleDraft(parsing: "*/15 * * * *").preset == .custom)
    #expect(RoutineScheduleDraft.describe("0 * * * *") == "Every hour")
    #expect(RoutineScheduleDraft.describe("5 7 * * *") == "Daily at 07:05")
    #expect(RoutineScheduleDraft.describe("30 8 * * 1-5") == "Weekdays at 08:30")
    #expect(RoutineScheduleDraft.describe("0 18 * * 5") == "Fridays at 18:00")
    #expect(RoutineScheduleDraft.describe("every 30m") == "Every 30 min")
    #expect(RoutineScheduleDraft.describe("every 120m") == "Every 2 hours")
    #expect(RoutineScheduleDraft.describe("every 1d") == "Every day")
    #expect(RoutineScheduleDraft.describe("*/15 9-17 * * 1-5") == "Cron */15 9-17 * * 1-5")
    #expect(RoutineScheduleDraft.describe("When CI completes") == "When CI completes")
}

@Test func hermesTimesAndJobShapesParse() throws {
    let micro = try #require(RoutineTime.date("2026-10-13T09:00:06.123456+02:00"))
    #expect(micro == RoutineTime.date("2026-10-13T07:00:06Z"))
    #expect(RoutineTime.isLater("2026-10-13T09:00:06.5+02:00", than: "2026-10-13T08:59:00+02:00"))
    #expect(!RoutineTime.isLater("2026-10-13T08:00:00+02:00", than: "2026-10-13T09:00:00+02:00"))
    #expect(RoutineTime.isLater("2026-10-13T08:00:00+02:00", than: ""))
    let now = try #require(RoutineTime.date("2026-10-13T11:00:00+00:00"))
    #expect(RoutineTime.relative("2026-10-13T09:00:00+00:00", now: now) == "2 hours ago")

    var interval = jobPayload(id: "0123456789ab", name: "Pulse", enabled: false)
    interval["schedule"] = ["kind": "interval", "minutes": 30, "display": "every 30m"]
    let job = try #require(HermesJob.parse(interval))
    #expect(job.schedule == "every 30m" && job.scheduleKind == "interval" && job.isPaused && job.lastRunAt == nil && job.lastError == nil)
    #expect(HermesJob.isValidID("0123456789ab") && !HermesJob.isValidID("../../etc") && !HermesJob.isValidID("0123456789AB"))
}

@Test func runSessionMatchesIdOrTitleAndIgnoresLaterRuns() throws {
    let job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Morning   brief", lastRunAt: "2026-10-13T09:00:30+00:00")))
    let finished = try #require(RoutineTime.date("2026-10-13T09:00:30+00:00")).timeIntervalSince1970
    let rows: [[String: Any]] = [
        ["id": "cron_00000000beef_20261013_090000", "source": "cron", "title": "Morning brief · Oct 13 09:00", "started_at": finished - 30],
        ["id": "cron_00000000beef_20261013_100000", "source": "cron", "title": "Morning brief · Oct 13 10:00", "started_at": finished + 3600],
        ["id": "rotated_tip", "source": "cron", "title": "Morning brief · Oct 12 09:00", "started_at": finished - 86_400],
        ["id": "cron_other_x", "source": "cron", "title": "Other · Oct 13 09:00", "started_at": finished],
        ["id": "api_chat", "source": "api_server", "title": "Morning brief · Oct 13 09:00", "started_at": finished],
    ]
    #expect(HermesJobsClient.latestRunSession(rows, job: job, finishedAt: RoutineTime.date(job.lastRunAt!))?["id"] as? String == "cron_00000000beef_20261013_090000")
    #expect(HermesJobsClient.latestRunSession(Array(rows[2...]), job: job, finishedAt: nil)?["id"] as? String == "rotated_tip", "compression-rotated sessions match by title")
}

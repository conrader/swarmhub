import Foundation
import Testing
@testable import AgentApp

@MainActor struct RoutineDeliveryTests {
    func store(_ url: URL) -> AppStore { AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()) }

    @Test func restartProjectsCommittedRoutineWithoutDuplicate() throws {
        let url = temporaryStore(); let store = store(url)
        let bot = Bot(name: "Routine owner"); store.bots = [bot]; store.save()
        let message = ChatMessage(role: .assistant, content: String(repeating: "full output ", count: 50), presentation: .routineResult, metadata: ["deliveryKey": "fixture-run"])
        // Crash boundary: the ledger committed the card, store.json was not written.
        try store.journal().put(RoutineDelivery(id: "fixture-run", botID: bot.id, message: message), kind: AppStore.routineDeliveryKind, id: "fixture-run")
        let reopened = self.store(url)
        #expect(reopened.bots.first?.messages.map(\.content) == [message.content])
        reopened.restoreRoutineDeliveries()
        #expect(reopened.bots.first?.messages.count == 1)
    }

    @Test func pendingRoutineIsRetiredWhenOutputArrivesBeforeRestart() throws {
        let url = temporaryStore(); let store = store(url)
        let bot = Bot(name: "Routine owner"); store.bots = [bot]
        var job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Digest", lastRunAt: "2026-10-15T09:00:00+00:00")))
        try store.deliverRoutine(job, result: nil, bot: bot, lookupError: "Pending")
        let beforeResult = try Data(contentsOf: url)
        job.lastRunAt = "2026-10-15T09:00:00Z"
        try store.deliverRoutine(job, result: .init(sessionID: "cron-result", text: "Complete output"), bot: bot, lookupError: nil)
        try store.deliverRoutine(job, result: nil, bot: bot, lookupError: "Stale poll")
        #expect(bot.messages.map(\.content) == ["Complete output"])
        // The store.json projection is lost; the ledger is kept.
        try beforeResult.write(to: url, options: .atomic)
        let reopened = self.store(url)
        #expect(reopened.bots.first?.messages.map(\.content) == ["Complete output"])
        #expect(reopened.bots.first?.messages.first?.metadata["sessionID"] == "cron-result")
    }

    @Test func theSameRunDeliveredTwiceIsOneCardAndOneNotificationMark() throws {
        let store = store(temporaryStore())
        let bot = Bot(name: "Routine owner"); store.bots = [bot]
        let job = try #require(HermesJob.parse(jobPayload(id: "00000000beef", name: "Digest", lastRunAt: "2026-10-15T09:00:00+00:00")))
        try store.deliverRoutine(job, result: .init(sessionID: "cron-1", text: "Output"), bot: bot, lookupError: nil)
        try store.deliverRoutine(job, result: .init(sessionID: "cron-1", text: "Output"), bot: bot, lookupError: nil)
        #expect(bot.messages.count == 1 && bot.unreadCount == 1)
        let records = try store.journal().records(RoutineDelivery.self, kind: AppStore.routineDeliveryKind)
        #expect(records.count == 1 && records[0].notified && records[0].delivered)
    }

    @Test func runsMissedWhileClosedAreCaughtUpOldestFirst() async throws {
        let server = FakeJobsServer()
        server.add(jobPayload(id: "00000000beef", name: "Morning brief", lastRunAt: "2026-10-12T09:00:04+02:00", lastStatus: "ok"))
        let (store, bot, _) = routinesStore(server)
        let now = Date()
        await store.pollRoutinesOnce(now: now)
        #expect(bot.messages.isEmpty)
        server.finishRun("00000000beef", at: "2026-10-13T09:00:06+02:00", sessionStarted: 1_791_874_800, reply: "Monday")
        server.finishRun("00000000beef", at: "2026-10-14T09:00:06+02:00", sessionStarted: 1_791_961_200, reply: "Tuesday")
        await store.pollRoutinesOnce(now: now.addingTimeInterval(61))
        #expect(bot.messages.map(\.content) == ["Monday", "Tuesday"])
        #expect(bot.messages.map { $0.metadata["sessionID"] } == ["cron_00000000beef_1791874800", "cron_00000000beef_1791961200"])
        #expect(bot.unreadCount == 2)
        await store.pollRoutinesOnce(now: now.addingTimeInterval(122))
        #expect(bot.messages.count == 2, "no run is carded twice")
    }

    @Test func repauseAfterRunNowSurvivesARelaunch() async throws {
        let server = FakeJobsServer()
        server.add(jobPayload(id: "00000000beef", name: "Weekly", enabled: false, lastRunAt: "2026-10-12T09:00:04+02:00"))
        let url = temporaryStore()
        let (store, bot, _) = routinesStore(server, url: url)
        await store.pollRoutinesOnce(now: Date())
        let job = try #require(store.routines.state(for: bot.id).jobs.value?.first)
        await store.runRoutineNow(job, for: bot)
        #expect(store.routines.repauseAfterRun.count == 1)
        let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: store.keyStore, defaults: store.defaults, hermesSession: store.hermesSession)
        #expect(reopened.routines.repauseAfterRun == store.routines.repauseAfterRun)
    }
}

import Foundation
import Testing
@testable import AgentApp

// P43 part 2: routines show what they do. Run now shows Running… at once and the card arrives as soon as the run is
// seen (a 5 s watch with an injected sleep, never the 60 s inbox gate); a bot's cron step refreshes its routines; Open
// result reads the run's whole output. Synthetic jobs server only (`FakeJobsServer`).

/// A sleep the test releases: each call waits until `release()` and then returns.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock(); private var open = false
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
    func sleep(_: Duration) async throws {
        while !isOpen { try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor private func watchedStore(_ server: FakeJobsServer) -> (AppStore, Bot, String, SleepGate) {
    let (store, bot, host) = routinesStore(server)
    let gate = SleepGate()
    store.routines.autoLoad = true
    store.routineWatchSleep = { try await gate.sleep($0) }
    return (store, bot, host, gate)
}

@Test @MainActor func runNowShowsRunningAtOnceAndTheCardArrivesWithoutTheInboxGate() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "1c33e2cfacf1", name: "Onboarding audit", lastRunAt: "2026-10-15T19:00:00+02:00", lastStatus: "ok"))
    let (store, bot, host, gate) = watchedStore(server)
    #expect(await store.refreshRoutines(for: bot))
    let job = try #require(store.routines.state(for: bot.id).jobs.value?.first)

    await store.runRoutineNow(job, for: bot)
    #expect(RoutineWatch.isRunning(job, in: store.routines.state(for: bot.id)), "Running… from the click")
    // A second click while it runs sends nothing.
    await store.runRoutineNow(job, for: bot)
    #expect(requestLines(host).filter { $0.hasSuffix("/run") }.count == 1)

    server.finishRun(job.id, at: "2026-10-15T20:06:30+02:00", sessionStarted: 1_760_551_440, reply: "Audit done: README is current.")
    gate.release()
    try await waitUntil { bot.messages.contains { $0.presentation == .routineResult } && store.routines.state(for: bot.id).running.isEmpty }
    let card = try #require(bot.messages.last { $0.presentation == .routineResult })
    #expect(card.content == "Audit done: README is current." && card.metadata["sessionID"] != nil)
    #expect(!RoutineWatch.isRunning(store.routines.state(for: bot.id).jobs.value!.first!, in: store.routines.state(for: bot.id)))
    #expect(store.routines.watches.isEmpty)
}

@Test func serverFactsMarkARunUnderWay() throws {
    var row = jobPayload(id: "1c33e2cfacf1", name: "Audit", lastRunAt: "2026-10-15T19:00:00+02:00")
    row["manual_run_at"] = "2026-10-15T20:03:01+02:00"
    let manual = try #require(HermesJob.parse(row))
    #expect(manual.manualRunAt == "2026-10-15T20:03:01+02:00" && RoutineWatch.serverSaysRunning(manual))
    row["last_run_at"] = "2026-10-15T20:06:30+02:00"
    #expect(!RoutineWatch.serverSaysRunning(try #require(HermesJob.parse(row))), "a manual run older than the last run is over")
    row["manual_run_at"] = NSNull(); row["fire_claim"] = ["owner": "scheduler-1", "claimed_at": "2026-10-15T20:03:02+02:00"]
    #expect(try #require(HermesJob.parse(row)).fireClaimed)
    row["fire_claim"] = NSNull()
    #expect(!(try #require(HermesJob.parse(row))).fireClaimed)
}

@Test @MainActor func aBotsCronStepRefreshesItsRoutines() async throws {
    let server = FakeJobsServer()
    let (store, bot, _, _) = watchedStore(server)
    #expect(await store.refreshRoutines(for: bot))
    #expect(store.routines.state(for: bot.id).jobs.value?.isEmpty == true)
    // The bot creates a job with its cron tool; the list updates when the step ends, not on the 60 s gate.
    server.add(jobPayload(id: "0123456789ab", name: "Daily digest"))
    let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
    continuation.yield(.tool(ToolEvent(phase: .started, name: "cronjob", preview: "create Daily digest")))
    continuation.yield(.tool(ToolEvent(phase: .completed, name: "cronjob")))
    continuation.yield(.completed); continuation.finish()
    let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
    bot.messages.append(reply)
    _ = try await store.consumeTurn(stream, assistant: reply, bot: bot, sessionID: "s", backend: MockBackend()) { _ in }
    try await waitUntil { store.routines.state(for: bot.id).jobs.value?.map(\.name) == ["Daily digest"] }
}

@Test @MainActor func openResultLoadsTheRunsWholeOutput() async throws {
    let server = FakeJobsServer()
    let long = String(repeating: "Line of the audit report. ", count: 40)
    server.add(jobPayload(id: "1c33e2cfacf1", name: "Onboarding audit"))
    server.finishRun("1c33e2cfacf1", at: "2026-10-15T20:06:30+02:00", sessionStarted: 1_760_551_440, reply: long)
    let (store, bot, _) = routinesStore(server)
    let job = try #require(try await store.jobsClient(for: bot).list().first)
    let result = try #require(try await store.jobsClient(for: bot).runResult(for: job))
    let card = AppStore.routineCard(job: job, result: result, lookupError: nil)
    #expect(card.content.count < long.trimmingCharacters(in: .whitespaces).count, "the card keeps a summary")
    let full = try await store.routineFullResult(sessionID: try #require(card.metadata["sessionID"]), bot: bot)
    #expect(full == long.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test @MainActor func aFailedRunsCardSaysSoWithItsError() throws {
    var job = try #require(HermesJob.parse(jobPayload(id: "1c33e2cfacf1", name: "Audit", lastRunAt: "2026-10-15T20:06:30+02:00", lastStatus: "error", lastError: "Model quota exceeded")))
    job.lastStatus = "error"
    let card = AppStore.routineCard(job: job, result: .init(sessionID: "cron_1c33e2cfacf1_1", text: ""), lookupError: nil)
    #expect(RoutineResultCopy.failed(card) && RoutineResultCopy.title(card) == "Routine failed · error" && card.metadata["error"] == "Model quota exceeded")
    let ok = AppStore.routineCard(job: { var ok = job; ok.lastStatus = "ok"; ok.lastError = nil; return ok }(), result: nil, lookupError: nil)
    #expect(RoutineResultCopy.title(ok) == "Routine finished · ok")
}

@Test @MainActor func aCardReachesTheMainChatWhileASideThreadIsOpenAndBadgesIt() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Reactor", backend: .hermes, hermesProfile: "reactor")
    let parent = ChatMessage(role: .assistant, content: "Parent")
    let thread = ChatThread(parentMessageID: parent.id, parentSessionID: "main", hermesSessionID: "side")
    bot.messages = [parent]; bot.threads = [thread]; store.bots = [bot]
    store.open(bot); store.openThreadID = thread.id
    let job = try #require(HermesJob.parse(jobPayload(id: "1c33e2cfacf1", name: "Audit", lastRunAt: "2026-10-15T20:06:30+02:00", lastStatus: "ok")))
    try store.deliverRoutine(job, result: .init(sessionID: "cron_1c33e2cfacf1_1", text: "Done."), bot: bot, lookupError: nil)
    #expect(bot.messages.last?.presentation == .routineResult && thread.messages.isEmpty)
    #expect(bot.unreadCount == 1)
    store.closeThread()
    #expect(bot.unreadCount == 0, "back in the chat, the card is seen")
}

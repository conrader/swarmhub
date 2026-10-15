import Foundation
import Testing
@testable import AgentApp

// P45 3: /loop — interval, --times, --until, pause/stop; nothing runs after Stop. Injected clock, `automationTick()` by hand.

@MainActor private func loopStore(_ backend: ScriptedTurnBackend) -> (AppStore, Bot, (TimeInterval) -> Void) {
    let (store, bot) = steerStore(backend)
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    store.now = { clock }
    return (store, bot, { clock = clock.addingTimeInterval($0) })
}

@MainActor private func answer(_ backend: ScriptedTurnBackend, _ store: AppStore, _ text: String = "ok") async throws {
    await backend.emit(.token(text), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
}

@Test func loopArgumentsParse() throws {
    let now = Date(timeIntervalSince1970: 0)
    let a = try LoopRun.parse("every 5m check the build --times 3", now: now).get()
    #expect(a.interval == 300 && a.prompt == "check the build" && a.timesLeft == 3 && a.until == nil)
    let b = try LoopRun.parse("2 hours summarise mail --until inbox zero", now: now).get()
    #expect(b.interval == 7200 && b.prompt == "summarise mail" && b.until == "inbox zero")
    let c = try LoopRun.parse("ping the box", now: now).get()
    #expect(c.interval == ScheduleInterval.defaultLoop && c.prompt == "ping the box")
    #expect(try LoopRun.parse("10s too fast", now: now).get().interval == 60, "at least 1 min")
    #expect(LoopRun.parse("5m", now: now) == .failure(.noPrompt) && LoopRun.parse("x --times zero", now: now) == .failure(.badTimes))
    #expect(a.label == "Loop · every 5 min · 3 left" && ScheduleInterval.label(3600) == "hourly")
}

@MainActor @Test func aLoopResendsOnItsIntervalAndEndsAfterItsTimes() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, advance) = loopStore(backend)
    #expect(store.submitComposer(text: "/loop 5m check the build --times 2"))
    try await backend.calls.wait { $0.contains("send:check the build") }
    #expect(bot.messages.contains { $0.content.hasPrefix("Loop started: Loop · every 5 min · 2 left.") && $0.content.contains("Routines") })
    let sent = try #require(bot.messages.last { $0.role == .user })
    #expect(AutomationCopy.wokenBy(sent) == "Woken by: loop")
    try await answer(backend, store)
    store.automationTick()
    #expect(await backend.streamCount == 1, "not due yet")
    advance(299); store.automationTick()
    #expect(await backend.streamCount == 1)
    advance(1); store.automationTick()
    try await waitUntil { await backend.streamCount == 2 }
    try await answer(backend, store)
    #expect(store.loop(in: bot) == nil && bot.messages.last?.content == "Loop finished after 2 runs.")
    advance(600); store.automationTick()
    #expect(await backend.streamCount == 2)
}

@MainActor @Test func aLoopEndsWhenTheBotReportsItsUntilCondition() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, advance) = loopStore(backend)
    #expect(store.submitComposer(text: "/loop 1m is CI green --until CI is green"))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:is CI green") && $0.contains("when this is true — CI is green —") } }
    try await answer(backend, store, "Still red.")
    advance(60); store.automationTick()
    try await waitUntil { await backend.streamCount == 2 }
    try await answer(backend, store, "Green now.\n```swarmhub\n{\"op\":\"loop\",\"status\":\"done\"}\n```")
    #expect(store.loop(in: bot) == nil && bot.messages.last?.content == "Loop ended: CI is green.")
}

@MainActor @Test func pauseResumeAndStopAndNothingRunsAfterStop() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, advance) = loopStore(backend)
    #expect(store.submitComposer(text: "/loop 1m status report"))
    try await waitUntil { await backend.streamCount == 1 }
    try await answer(backend, store)
    #expect(store.submitComposer(text: "/loop pause"))
    advance(120); store.automationTick()
    #expect(await backend.streamCount == 1, "paused")
    #expect(store.submitComposer(text: "/loop status"))
    #expect(bot.messages.last?.content.hasPrefix("Loop · every 1 min · paused · sent 1") == true)
    #expect(store.submitComposer(text: "/loop resume"))
    try await waitUntil { await backend.streamCount == 2 }
    // Stop while the loop's turn runs: the turn and the loop end.
    #expect(store.submitComposer(text: "/stop"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.loop(in: bot) == nil && bot.messages.contains { $0.content == "Loop stopped." })
    advance(3600); store.automationTick()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 2, "nothing runs after Stop")
}

@MainActor @Test func theComposerStopButtonEndsTheLoopToo() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, advance) = loopStore(backend)
    #expect(store.submitComposer(text: "/loop 1m poll"))
    try await waitUntil { await backend.streamCount == 1 }
    store.stop(bot)
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.loop(in: bot) == nil)
    advance(120); store.automationTick()
    #expect(await backend.streamCount == 1)
}

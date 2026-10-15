import Foundation
import Testing
@testable import AgentApp

// P45 5: /heartbeat — the schedule window, idle only, [SILENT] hidden, pause/stop, restart. Injected clock; no network.

/// Local time today at `hour`:`minute` (the window is local time).
private func local(_ hour: Int, _ minute: Int = 0) -> Date {
    var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: 1_800_000_000))
    parts.hour = hour; parts.minute = minute
    return Calendar.current.date(from: parts)!
}

@MainActor private func heartbeatStore(_ backend: ScriptedTurnBackend, at start: Date, url: URL = temporaryStore()) -> (AppStore, Bot, (Date) -> Void) {
    let (store, bot) = steerStore(backend, url: url)
    var clock = start
    store.now = { clock }
    return (store, bot, { clock = $0 })
}

@Test func heartbeatArgumentsAndWindow() throws {
    let run = try HeartbeatRun.parse("every 1h 08:00–23:00", now: local(7)).get()
    #expect(run.interval == 3600 && run.windowStart == 480 && run.windowEnd == 1380 && run.prompt == HeartbeatRun.defaultPrompt)
    #expect(run.label == "Heartbeat · hourly 08–23")
    #expect(run.inWindow(local(8)) && run.inWindow(local(23)) && !run.inWindow(local(7, 59)) && !run.inWindow(local(23, 1)))
    let night = try HeartbeatRun.parse("every 30 min 22:30-06:00 check the backups", now: local(0)).get()
    #expect(night.prompt == "check the backups" && night.label == "Heartbeat · every 30 min 22:30–06")
    #expect(night.inWindow(local(23)) && night.inWindow(local(5)) && !night.inWindow(local(12)))
    #expect(HeartbeatRun.parse("soon", now: local(0)) == .failure(.noInterval))
    #expect(HeartbeatRun.isSilent("  [silent]\n") && !HeartbeatRun.isSilent("[SILENT] but one thing"))
}

@MainActor @Test func aHeartbeatRunsInsideItsWindowAndASilentReplyIsHidden() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, set) = heartbeatStore(backend, at: local(6, 30))
    let other = Bot(name: "Other", backend: .hermes, hermesProfile: "default"); store.bots.append(other); store.selectedBot = other
    bot.messages = [ChatMessage(role: .user, content: "deploy it"), ChatMessage(role: .assistant, content: "Deployed.", turnState: .finished)]
    store.heartbeatCommand("every 1h 08:00–23:00", conversation: bot)
    #expect(store.heartbeat(in: bot)?.nextAt == local(7, 30))
    set(local(7, 30)); store.automationTick()
    #expect(await backend.streamCount == 0, "before the window: skipped")
    #expect(store.heartbeat(in: bot)?.nextAt == local(8, 30))
    set(local(8, 30)); store.automationTick()
    try await backend.calls.wait { $0.contains("send:\(HeartbeatRun.defaultPrompt)") }
    let prompt = try #require(bot.messages.last { $0.role == .user })
    #expect(AutomationCopy.wokenBy(prompt) == "Woken by: heartbeat")
    await backend.emit(.token("[SILENT]"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.filter(\.isSilentHeartbeat).count == 2, "the prompt and its reply")
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil) == "Deployed.", "no preview change")
    #expect(bot.unreadCount == 0 && !bot.manualUnread)

    // A reply with something to say stays.
    set(local(9, 30)); store.automationTick()
    try await waitUntil { await backend.streamCount == 2 }
    await backend.emit(.token("The backup failed at 09:10."), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.last?.isSilentHeartbeat == false && store.heartbeat(in: bot)?.runs == 2)
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil) == "The backup failed at 09:10.")
}

@MainActor @Test func aHeartbeatWaitsForAnIdleChat() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot, set) = heartbeatStore(backend, at: local(10))
    store.heartbeatCommand("every 1h", conversation: bot)
    #expect(store.submitComposer(text: "long job"))
    try await waitUntil { await backend.streamCount == 1 }
    set(local(11, 5)); store.automationTick()
    #expect(await backend.streamCount == 1, "busy: not now")
    await backend.emit(.token("done"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    store.goalCommand("polish docs", bot: bot, conversation: bot)
    try await waitUntil { await backend.streamCount == 2 }
    await backend.emit(.token("still going"), .completed); await backend.end()
    try await waitUntil { await backend.streamCount == 3 }
    store.goalCommand("pause", bot: bot, conversation: bot)
    await backend.emit(.token("paused here"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
    store.automationTick()
    try await backend.calls.wait { $0.contains("send:\(HeartbeatRun.defaultPrompt)") }
    #expect(await backend.streamCount == 4, "idle and the goal paused: the beat goes")
    await backend.emit(.token("[SILENT]"), .completed); await backend.end()
    try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func pauseStopAndRestart() async throws {
    let url = temporaryStore()
    let backend = ScriptedTurnBackend(); let (store, bot, set) = heartbeatStore(backend, at: local(12), url: url)
    #expect(store.submitComposer(text: "/heartbeat every 2h"))
    #expect(bot.messages.last?.content.hasPrefix("Heartbeat started: Heartbeat · every 2 h.") == true)
    #expect(store.submitComposer(text: "/heartbeat pause"))
    set(local(15)); store.automationTick()
    #expect(await backend.streamCount == 0)
    store.save()

    let later = ScriptedTurnBackend()
    let restarted = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in later }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    restarted.now = { local(15) }
    let again = try #require(restarted.bots.first { $0.id == bot.id })
    #expect(restarted.heartbeat(in: again)?.paused == true && restarted.heartbeat(in: again)?.label == "Heartbeat · every 2 h")
    restarted.heartbeatCommand("resume", conversation: again); restarted.automationTick()
    try await later.calls.wait { $0.contains("send:\(HeartbeatRun.defaultPrompt)") }
    await later.emit(.token("[SILENT]"), .completed); await later.end()
    try await waitUntil { !restarted.anyTurnRunning }
    restarted.heartbeatCommand("stop", conversation: again)
    #expect(restarted.heartbeat(in: again) == nil && restarted.automations[again.id] == nil)
    restarted.now = { local(23) }; restarted.automationTick()
    #expect(await later.streamCount == 1)
}

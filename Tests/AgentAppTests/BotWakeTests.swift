import Foundation
import Testing
@testable import AgentApp

// P42 8: every wake is visible in the woken bot's chat: a routine run's cron session live ("Woken by: routine …", P43's
// card stays the end) and a late reply delivered back to the asking bot ("Woken by: reply from Infra"). Synthetic only.

@Test @MainActor func aRoutineRunShowsLiveAsAWake() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, _, infra) = workStore(clock: clock)
    let job = try #require(HermesJob.parse(["id": "1c33e2cfacf1", "name": "Morning report", "prompt": "Summarise the night.", "schedule": "0 7 * * *",
                                            "state": "running", "last_run_at": "2027-01-15T07:00:00+00:00"]))
    store.routines.replaceJob(job, botID: infra.id)
    let previous = try #require(RoutineTime.date("2027-01-15T07:00:00+00:00"))
    let session = "cron_1c33e2cfacf1_20270116_070001"
    store.botWork.sessionsOverride = { bot, source in
        #expect(bot.id == infra.id && source == "cron")
        return [BotSessionRow(id: "cron_1c33e2cfacf1_20270115_070001", source: "cron", startedAt: previous.addingTimeInterval(-40)),
                BotSessionRow(id: "cron_other_20270116_070001", source: "cron", startedAt: previous.addingTimeInterval(86_400)),
                BotSessionRow(id: session, source: "cron", startedAt: previous.addingTimeInterval(86_401))]
    }
    let start = previous.addingTimeInterval(86_401)
    var tool = BackendMessage(id: 2, role: "assistant", content: "", createdAt: start.addingTimeInterval(2), tools: ["web_search"]); tool.toolPreviews = ["overnight alerts"]
    let stages = [[BackendMessage(id: 1, role: "user", content: "Summarise the night.", createdAt: start), tool],
                  [BackendMessage(id: 1, role: "user", content: "Summarise the night.", createdAt: start), tool,
                   BackendMessage(id: 3, role: "assistant", content: "Quiet night; one disk alert.", createdAt: start.addingTimeInterval(9), finishReason: "stop")]]
    let thread = GrowingThread(stages); thread.attach(store, recipient: infra, session: session)
    store.watchRoutineSession(job.id, since: job.lastRunAt, bot: infra)
    await finishWatches(store)
    #expect(thread.seen.first?.line == nil && thread.seen.dropFirst().allSatisfy { $0.line == "Working… · routine Morning report" })
    let card = try #require(infra.messages.last)
    #expect(card.content == "Woken by: routine Morning report" && card.metadata[BotMessageKey.session] == session)
    #expect(card.metadata[BotWorkKey.request] == "Summarise the night." && card.activity?.steps.map(\.preview) == ["overnight alerts"])
    #expect(card.metadata[BotWorkKey.reply] == nil && !card.isStreaming, "the result is P43's card, after this one")
    #expect(!store.hasBotMessageBadge(infra))
}

@Test @MainActor func aLateReplyWakesTheSenderVisibly() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, jarvis, _) = workStore(clock: clock)
    let rows = [BackendMessage(id: 7, role: "user", content: "[Reply from grok-infra via SwarmHub]\nDisk at 62 %, backup ok.", createdAt: clock.now),
                BackendMessage(id: 8, role: "assistant", content: "Infra answered: the backup is fine. Telling Konrad.", createdAt: clock.now.addingTimeInterval(5), finishReason: "stop")]
    store.botWork.rowsOverride = { bot, session in
        #expect(bot.id == jarvis.id && session == "swarmhub-from-grok-infra")
        return rows
    }
    store.applyBotThreadRows([], recipient: jarvis)
    store.applyBotThreadRows([BotThreadRow(sessionID: "swarmhub-from-grok-infra", sender: "grok-infra", mark: "2", updatedAt: clock.now, preview: nil)], recipient: jarvis)
    await finishWatches(store)
    let card = try #require(jarvis.messages.last)
    #expect(card.content == "Woken by: reply from Infra" && card.metadata[BotWorkKey.origin] == "reply:grok-infra")
    #expect(card.metadata[BotWorkKey.request] == "Disk at 62 %, backup ok." && card.metadata[BotWorkKey.reply] == "Infra answered: the backup is fine. Telling Konrad.")
    #expect(store.hasBotMessageBadge(jarvis))
}

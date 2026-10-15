import Foundation
import Testing
@testable import AgentApp

// P44 3: `[SILENT]` routine results and delivered messages. Synthetic jobs on FakeJobsServer only.

@Test func onlyTheWholeMarkerInAnyCaseIsSilent() {
    #expect(SilentReply.isSilent("[SILENT]") && SilentReply.isSilent("  [silent]\n") && SilentReply.isSilent("[Silent]"))
    #expect(!SilentReply.isSilent("[SILENT] but the disk is full") && !SilentReply.isSilent("SILENT") && !SilentReply.isSilent(""))
    #expect(!ChatMessage(role: .user, content: "[SILENT]").isSilent, "the user's own text is never hidden")
}

@MainActor @Test func aSilentRunPostsNoCardAndANonSilentRunDoes() async throws {
    let server = FakeJobsServer()
    server.add(jobPayload(id: "00000000beef", name: "jarvis-hourly-heartbeat-cet", lastRunAt: "2026-10-15T20:00:04+02:00", lastStatus: "ok"))
    let (store, bot, _) = routinesStore(server)
    bot.messages = [ChatMessage(role: .assistant, content: "Earlier answer", createdAt: Date().addingTimeInterval(-3600), turnState: .finished)]
    let now = Date()
    await store.pollRoutinesOnce(now: now)
    server.finishRun("00000000beef", at: "2026-10-15T20:47:06+02:00", sessionStarted: 1_792_090_020, reply: " [SILENT]\n")
    await store.pollRoutinesOnce(now: now.addingTimeInterval(61))
    #expect(bot.messages.map(\.content) == ["Earlier answer"] && bot.unreadCount == 0)
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil) == "Earlier answer")
    let state = store.routines.state(for: bot.id)
    let job = try #require(state.jobs.value?.first)
    let silent = AppStore.sameRoutineRun(state.silentRuns[job.id], job.lastRunAt)
    #expect(silent && RoutineRowCopy.timing(job, running: false, silent: silent).contains("· ok · silent"))
    // The ledger keeps the run, so a relaunch does not post it either.
    store.restoreRoutineDeliveries()
    #expect(bot.messages.count == 1)

    server.finishRun("00000000beef", at: "2026-10-15T21:01:06+02:00", sessionStarted: 1_792_090_860, reply: "The backup failed twice.")
    await store.pollRoutinesOnce(now: now.addingTimeInterval(122))
    #expect(bot.messages.map(\.content) == ["Earlier answer", "The backup failed twice."] && bot.unreadCount == 1)
    let after = store.routines.state(for: bot.id)
    let newer = try #require(after.jobs.value?.first)
    #expect(!AppStore.sameRoutineRun(after.silentRuns[newer.id], newer.lastRunAt))
    #expect(!RoutineRowCopy.timing(newer, running: false, silent: false).contains("silent"))
}

@MainActor @Test func silentCardsAlreadyInAStoredChatAreHidden() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis"); store.bots = [bot]
    let older = Date().addingTimeInterval(-7200), newer = Date().addingTimeInterval(-60)
    let card = ChatMessage(role: .assistant, content: "[SILENT]", createdAt: newer, presentation: .routineResult,
                           metadata: ["routine": "jarvis-hourly-heartbeat-cet", "status": "ok", "jobID": "beef", "runAt": "2026-10-15T20:47:06+02:00", "deliveryKey": "run-2047"])
    let legacy = ChatMessage(role: .assistant, content: "[SILENT]", createdAt: newer, presentation: .routineResult, metadata: ["routine": "old", "status": "ok"])
    bot.messages = [ChatMessage(role: .assistant, content: "Real news", createdAt: older), card, legacy]
    store.save()
    try store.journal().put(RoutineDelivery(id: "run-2047", botID: bot.id, message: card, delivered: true, notified: true), kind: AppStore.routineDeliveryKind, id: "run-2047")
    // Never shown, previewed or dated, whatever the path that stored them.
    #expect(bot.messages.filter { !$0.isSilent }.map(\.content) == ["Real news"])
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: false, archiveNewest: nil) == "Real news")
    #expect(SidebarChat.bot(bot).latestMessageDate(archive: nil) == older)
    // The ledger's silent record leaves the chat on launch and marks the run silent for the Routines tab.
    let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    reopened.restoreRoutineDeliveries()
    let restored = try #require(reopened.bots.first)
    #expect(!restored.messages.contains { $0.metadata["deliveryKey"] == "run-2047" })
    #expect(reopened.routines.state(for: restored.id).silentRuns["beef"] == "2026-10-15T20:47:06+02:00")
}

@MainActor @Test func aSilentMessageAddedByReconcileIsNotUnread() async throws {
    let (store, bots, states) = reconcileStore(bots: ["Jarvis"])
    let bot = bots[0]; bot.hermesSessionID = "s-jarvis"
    let start = Date().addingTimeInterval(-60)
    states[0].add("s-jarvis", "user", "status?", time: start.timeIntervalSince1970)
    states[0].add("s-jarvis", "assistant", "All quiet.", finish: "stop", time: start.addingTimeInterval(2).timeIntervalSince1970)
    states[0].add("s-jarvis", "user", "hourly check", time: start.addingTimeInterval(30).timeIntervalSince1970)
    states[0].add("s-jarvis", "assistant", "[SILENT]", finish: "stop", time: start.addingTimeInterval(32).timeIntervalSince1970)
    bot.messages = [ChatMessage(role: .user, content: "status?", createdAt: start),
                    ChatMessage(role: .assistant, content: "All quiet.", createdAt: start.addingTimeInterval(2), turnState: .finished)]
    store.selectedBot = nil
    await store.reconcile(bot, reason: .refresh)
    #expect(bot.messages.last?.content == "[SILENT]" && bot.messages.last?.isSilent == true)
    #expect(bot.unreadCount == 0)
}

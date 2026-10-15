import Foundation
import Testing
@testable import AgentApp

// P45 2: /goal — SwarmHub keeps sending rounds until the bot's goal block, Stop, pause/clear, a failure or the budget.
// Scripted backend, injected clock; no network.

private let doneReply = "All shipped.\n```swarmhub\n{\"op\":\"goal\",\"status\":\"done\",\"summary\":\"Notes written and merged.\"}\n```"
private let blockedReply = "I can't go on.\n```swarmhub\n{\"op\":\"goal\",\"status\":\"blocked\",\"need\":\"the deploy key\"}\n```"

@MainActor private func finish(_ backend: ScriptedTurnBackend, _ text: String) async {
    await backend.emit(.token(text), .completed); await backend.end()
}

@MainActor private func goalStore(_ backend: ScriptedTurnBackend, url: URL = temporaryStore()) -> (AppStore, Bot) {
    let (store, bot) = steerStore(backend, url: url)
    store.now = { Date(timeIntervalSince1970: 1_800_000_000) }
    return (store, bot)
}

@Test func theGoalBlockIsReadFromTheLastSwarmhubFence() {
    #expect(GoalProtocol.report(in: doneReply) == .done(summary: "Notes written and merged."))
    #expect(GoalProtocol.report(in: blockedReply) == .blocked(need: "the deploy key"))
    #expect(GoalProtocol.report(in: "```swarmhub\n{\"op\":\"avatar\"}\n```") == nil && GoalProtocol.report(in: "plain") == nil)
    #expect(SwarmhubBlock.visibleText(doneReply) == "All shipped.", "the block is not shown")
}

@MainActor @Test func aGoalRunsRoundsUntilTheDoneBlock() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal ship the release notes"))
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:[SwarmHub goal]") && $0.contains("ship the release notes") } }
    let first = try #require(bot.messages.first { $0.role == .user })
    #expect(first.metadata[AutomationKey.display] == "Goal: ship the release notes" && first.metadata[AutomationKey.woken] == nil)
    #expect(store.goal(in: bot)?.round == 1 && store.goal(in: bot)?.awaitingReply == true)

    await finish(backend, "Drafted the outline.")
    try await waitUntil { await backend.streamCount == 2 }
    let second = try #require(bot.messages.last { $0.role == .user })
    #expect(second.content.hasPrefix("Continue toward the goal: ship the release notes") && AutomationCopy.wokenBy(second) == "Woken by: goal")
    #expect(store.goal(in: bot)?.round == 2 && store.goal(in: bot)?.lastSummary == "Drafted the outline.")

    await finish(backend, doneReply)
    try await waitUntil { store.goal(in: bot)?.state == .done }
    let card = try #require(bot.messages.last)
    #expect(card.presentation == .automation && card.content == "Goal reached" && card.metadata[AutomationKey.detail] == "Notes written and merged.")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 2, "nothing is sent after done")
    #expect(store.automationStatusLines(for: bot) == ["Goal: ship the release notes · done · round 2/20"])
}

@MainActor @Test func aBlockedGoalWaitsForResume() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal deploy the site"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, blockedReply)
    try await waitUntil { store.goal(in: bot)?.state == .blocked }
    #expect(bot.messages.last?.content == "Goal blocked" && bot.messages.last?.metadata[AutomationKey.detail] == "the deploy key")
    store.resumeGoal(bot: bot, conversation: bot)
    try await waitUntil { await backend.streamCount == 2 }
    #expect(store.goal(in: bot)?.state == .running && store.goal(in: bot)?.need == nil)
    #expect(store.submitComposer(text: "/stop"))
    try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func theBudgetEndsAGoalByRoundsOrTime() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    store.defaults.set(2, forKey: GoalProtocol.roundsKey)
    #expect(store.submitComposer(text: "/goal keep polishing"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, "Round one.")
    try await waitUntil { await backend.streamCount == 2 }
    await finish(backend, "Round two.")
    try await waitUntil { store.goal(in: bot)?.state == .ended }
    #expect(bot.messages.last?.content == "Goal stopped: all 2 rounds used" && bot.messages.last?.metadata[AutomationKey.detail] == "Round two.")

    // Time: the clock passes the 2 h limit between rounds.
    let (timed, timedBot) = goalStore(backend)
    var clock = Date(timeIntervalSince1970: 1_800_000_000); timed.now = { clock }
    #expect(timed.submitComposer(text: "/goal a long one"))
    try await waitUntil { await backend.streamCount == 3 }
    clock = clock.addingTimeInterval(2 * 3600 + 1)
    await finish(backend, "Still going.")
    try await waitUntil { timed.goal(in: timedBot)?.state == .ended }
    #expect(timedBot.messages.last?.content == "Goal stopped: the 2 h limit reached")
}

@MainActor @Test func pauseResumeClearAndStatus() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal tidy the repo"))
    try await waitUntil { await backend.streamCount == 1 }
    #expect(store.submitComposer(text: "/goal pause"))
    await finish(backend, "Did a bit.")
    try await waitUntil { !store.anyTurnRunning && store.goal(in: bot)?.awaitingReply == false }
    let pausedCount = await backend.streamCount
    #expect(store.goal(in: bot)?.state == .paused && pausedCount == 1, "paused: the round ends, nothing more is sent")
    #expect(store.submitComposer(text: "/subgoal tests pass"))
    #expect(store.submitComposer(text: "/goal status"))
    let status = try #require(bot.messages.last?.content)
    #expect(status.contains("Goal: tidy the repo") && status.contains("Paused · round 1/20") && status.contains("1. tests pass") && status.contains("Last: Did a bit."))
    #expect(store.submitComposer(text: "/goal resume"))
    try await waitUntil { await backend.streamCount == 2 }
    #expect(bot.messages.last { $0.role == .user }?.content.contains("Also required:\n1. tests pass") == true)
    #expect(store.submitComposer(text: "/goal clear"))
    #expect(store.goal(in: bot) == nil)
    await finish(backend, "More.")
    try await waitUntil { !store.anyTurnRunning }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 2, "cleared: no further rounds")
}

@MainActor @Test func aGoalSurvivesARestartAndContinues() async throws {
    let url = temporaryStore()
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend, url: url)
    #expect(store.submitComposer(text: "/goal write the changelog"))
    try await waitUntil { await backend.streamCount == 1 }
    store.save()
    #expect(store.storedAutomations?[bot.id.uuidString]?.goal?.awaitingReply == true)

    let later = ScriptedTurnBackend()
    let restarted = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in later }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let again = try #require(restarted.bots.first)
    #expect(restarted.goal(in: again)?.state == .running && restarted.goal(in: again)?.awaitingReply == false && restarted.goal(in: again)?.round == 1)
    restarted.automationTick()
    try await later.calls.wait { $0.contains { $0.hasPrefix("send:Continue toward the goal: write the changelog") } }
    #expect(restarted.goal(in: again)?.round == 2)
    await finish(later, doneReply); try await waitUntil { !restarted.anyTurnRunning }
    await backend.end()
}

@MainActor @Test func offlinePausesTheGoalAndTheReturnResumesIt() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal sync the docs"))
    try await waitUntil { await backend.streamCount == 1 }
    await store.handle(.pathDown)
    await finish(backend, "Halfway.")
    try await waitUntil { store.goal(in: bot)?.pausedOffline == true }
    let offlineCount = await backend.streamCount
    #expect(store.goal(in: bot)?.state == .paused && offlineCount == 1)
    store.turns.pathDown = false; store.automationTick()
    try await waitUntil { await backend.streamCount == 2 }
    #expect(store.goal(in: bot)?.state == .running && store.goal(in: bot)?.round == 2)
    await finish(backend, doneReply); try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func aUserMessageSteersTheRoundAndStopEndsTheGoal() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal refactor the parser"))
    try await waitUntil { await backend.streamCount == 1 }
    // A running step: the typed text is queued into this round (P28 steer), the goal goes on.
    await backend.emit(.token("Working. "), step(.started))
    try await waitUntil { store.soleTurn?.steerAvailable == true && store.soleTurn?.assistant?.activity?.current != nil }
    #expect(store.submitComposer(text: "keep the public API"))
    try await backend.calls.wait { $0.contains("steer:keep the public API") }
    #expect(store.goal(in: bot)?.state == .running)
    // No step running: the text stops the answer and goes as a correction; that stop does not end the goal.
    await backend.emit(step(.completed))
    try await waitUntil { store.soleTurn?.assistant?.activity?.current == nil }
    #expect(store.submitComposer(text: "and keep it small"))
    try await waitUntil { await backend.streamCount == 2 }
    #expect(store.goal(in: bot)?.state == .running && bot.messages.last { $0.role == .user }?.content == "and keep it small")
    await finish(backend, "Smaller now.")
    try await waitUntil { await backend.streamCount == 3 }
    #expect(store.goal(in: bot)?.round == 2, "the correction's turn led to the next round")
    #expect(store.submitComposer(text: "/stop"))
    try await waitUntil { !store.anyTurnRunning }
    #expect(store.goal(in: bot)?.state == .ended && bot.messages.contains { $0.content == "Goal stopped" })
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 3, "nothing runs after Stop")
}

@MainActor @Test func aFailedTurnEndsTheGoal() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal fix CI"))
    try await waitUntil { await backend.streamCount == 1 }
    await backend.emit(.failed("model overloaded")); await backend.end()
    try await waitUntil { store.goal(in: bot)?.state == .ended }
    #expect(bot.messages.last?.content == "Goal stopped: the last turn failed" && bot.messages.last?.metadata[AutomationKey.detail] == "model overloaded")
    #expect(store.submitComposer(text: "/goal again"))
    try await waitUntil { await backend.streamCount == 2 }
    #expect(store.goal(in: bot)?.text == "again", "an ended goal can be replaced")
    await finish(backend, doneReply); try await waitUntil { !store.anyTurnRunning }
}

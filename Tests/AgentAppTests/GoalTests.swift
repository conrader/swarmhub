import Foundation
import Testing
@testable import AgentApp

// P45 2: /goal — SwarmHub keeps sending rounds until the bot's goal block, Stop, pause/clear, a failure or the budget.
// Scripted backend, injected clock; no network.

private let doneReply = "All shipped.\n```swarmhub\n{\"op\":\"goal\",\"status\":\"done\",\"summary\":\"Notes written and merged.\",\"evidence\":{\"commit\":\"abc1234\",\"report\":\"/tmp/notes-report.md\"}}\n```"
/// P01/P04 gap: a done block without evidence (the pass-4 shape) is not accepted.
private let bareDoneReply = "All shipped.\n```swarmhub\n{\"op\":\"goal\",\"status\":\"done\",\"summary\":\"Notes written and merged.\"}\n```"
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
    #expect(GoalProtocol.report(in: doneReply) == .done(summary: "Notes written and merged.", evidence: GoalEvidence(commit: "abc1234", report: "/tmp/notes-report.md")))
    #expect(GoalProtocol.report(in: bareDoneReply) == .done(summary: "Notes written and merged.", evidence: GoalEvidence()))
    #expect(GoalProtocol.report(in: blockedReply) == .blocked(need: "the deploy key"))
    #expect(GoalProtocol.report(in: "```swarmhub\n{\"op\":\"avatar\"}\n```") == nil && GoalProtocol.report(in: "plain") == nil)
    #expect(SwarmhubBlock.visibleText(doneReply) == "All shipped.", "the block is not shown")
}

@MainActor @Test func aGoalRunsRoundsUntilTheDoneBlock() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal --coding ship the release notes"))
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
    #expect(card.presentation == .automation && card.content == "Goal reached")
    #expect(card.metadata[AutomationKey.detail] == "Notes written and merged.\nClaimed by the bot, not verified by SwarmHub: commit abc1234; report /tmp/notes-report.md.")
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 2, "nothing is sent after done")
    #expect(store.automationStatusLines(for: bot) == ["Goal: ship the release notes · done · round 2/20"])
}

@Test func goalEvidenceRequiresACommitOrATestPassPlusAReport() {
    #expect(!GoalEvidence().isSufficient && GoalEvidence().missing == ["a commit id or a test pass", "the fresh report path"])
    #expect(GoalEvidence(commit: "abc1234", report: "/r").isSufficient && GoalEvidence(testsPassed: true, report: "/r").isSufficient)
    #expect(!GoalEvidence(commit: "abc1234").isSufficient && !GoalEvidence(report: "/r").isSufficient)
    // Placeholders from the protocol text never count as a commit; tests accept "passed" or true.
    #expect(GoalEvidence.parse(["commit": "<commit id you made>", "tests": "passed", "report": " /r "]) == GoalEvidence(testsPassed: true, report: "/r"))
    #expect(GoalEvidence.parse(["commit": "0123456789abcdef", "tests": true]) == GoalEvidence(commit: "0123456789abcdef", testsPassed: true))
    #expect(GoalEvidence.parse(["tests": "failed", "report": ""]) == GoalEvidence() && GoalEvidence.parse("text") == GoalEvidence())
    #expect(!GoalEvidence.parse(["tests": "passed", "report": "<fresh report path>"]).isSufficient)
    #expect(GoalEvidence(testsPassed: true).summary == "Claimed by the bot, not verified by SwarmHub: tests passed.\nMissing: the fresh report path.")
}

@MainActor @Test func evidenceRequestsRespectPauseAndTheRoundBudget() async throws {
    for paused in [true, false] {
        let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
        store.defaults.set(1, forKey: GoalProtocol.roundsKey)
        #expect(store.submitComposer(text: "/goal --coding finish within the budget"))
        try await waitUntil { await backend.streamCount == 1 }
        if paused { store.goalCommand("pause", bot: bot, conversation: bot) }
        await finish(backend, bareDoneReply)
        try await waitUntil { store.isIdle(bot) && store.goal(in: bot)?.awaitingReply == false }
        #expect(store.goal(in: bot)?.state == (paused ? .paused : .ended))
        #expect(await backend.streamCount == 1, "missing evidence cannot bypass pause or spend another round")
    }
}

@MainActor @Test func aDoneWithoutEvidenceIsSentBackAndThenBlocks() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal --coding ship the release notes"))
    try await waitUntil { await backend.streamCount == 1 }
    await finish(backend, bareDoneReply)
    try await waitUntil { await backend.streamCount == 2 }
    let card = try #require(bot.messages.last { $0.presentation == .automation })
    #expect(card.content == "Done claimed without evidence" && card.metadata[AutomationKey.card] == "goalUnverified")
    #expect(card.metadata[AutomationKey.detail] == "Claimed by the bot, not verified by SwarmHub: nothing.\nMissing: a commit id or a test pass; the fresh report path.")
    let request = try #require(bot.messages.last { $0.role == .user })
    #expect(request.content.hasPrefix("Your done block for the goal \"ship the release notes\" has no accepted evidence") && request.metadata[AutomationKey.display] == "Evidence for done")
    #expect(store.goal(in: bot)?.state == .running && store.goal(in: bot)?.evidenceRounds == 1 && store.goal(in: bot)?.round == 2)
    await finish(backend, bareDoneReply)
    try await waitUntil { await backend.streamCount == 3 }
    #expect(store.goal(in: bot)?.evidenceRounds == 2)
    await finish(backend, bareDoneReply)
    try await waitUntil { store.goal(in: bot)?.state == .blocked }
    #expect(bot.messages.last?.content == "Goal blocked" && store.goal(in: bot)?.need?.hasPrefix("evidence for done") == true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await backend.streamCount == 3, "nothing more is sent once blocked")
    // Resume asks again; evidence ends it as reached, with the claim marked unverified.
    store.resumeGoal(bot: bot, conversation: bot)
    try await waitUntil { await backend.streamCount == 4 }
    await finish(backend, doneReply)
    try await waitUntil { store.goal(in: bot)?.state == .done }
    #expect(bot.messages.last?.content == "Goal reached" && bot.messages.last?.metadata[AutomationKey.detail]?.contains("not verified by SwarmHub: commit abc1234") == true)
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

@MainActor @Test func atTheTurnLimitAGoalRoundWaitsLikeATypedMessage() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    let other = Bot(name: "Other", backend: .hermes, hermesProfile: "default", hermesSessionID: "session-other"); store.bots.append(other)
    store.turnLimits = TurnLimits(total: 1, perConnection: 1)
    #expect(store.send(text: "busy elsewhere", bot: other, conversation: other, replyToID: nil))
    try await waitUntil { await backend.streamCount == 1 }
    #expect(store.submitComposer(text: "/goal wait your turn"))
    #expect(store.hasWaitingTurn(in: bot) && store.goal(in: bot)?.awaitingReply == true, "the round waits as the chat's next message (P39)")
    #expect(await backend.streamCount == 1)
    await backend.emit(.token("done"), .completed); await backend.end()
    try await backend.calls.wait { $0.contains { $0.hasPrefix("send:[SwarmHub goal]") } }
    await backend.emit(.token("Round one."), .completed); await backend.end()
    try await waitUntil { await backend.streamCount == 3 }
    #expect(store.goal(in: bot)?.round == 2)
    await backend.emit(.token(doneReply), .completed); await backend.end()
    try await waitUntil { store.goal(in: bot)?.state == .done && !store.anyTurnRunning }
}

@Test func goalEvidenceFollowsExplicitTypeAndRejectsPlaceholders() {
    var goal = GoalRun(text: "Explain the result", maxRounds: 2, startedAt: Date(), maxDuration: 60)
    #expect(goal.accepts(GoalEvidence(deliverable: "Explanation in the cited article"), reply: ""))
    #expect(!goal.accepts(GoalEvidence.parse(["deliverable": "<actual result or source reference>"]), reply: ""))
    goal.codingEvidence = true
    #expect(!goal.accepts(GoalEvidence(deliverable: "Explanation"), reply: "Some prose"))
    #expect(goal.accepts(GoalEvidence(testsPassed: true, report: "/workspace/report.md"), reply: ""))
}

// Cross-review finding 8 and Codex issue B: the classification follows the requested action (change or build code
// versus explain or describe it), so plain coding requests without a keyword noun are coding and explanations are not.
@Test func plainGoalsAreClassifiedByTheRequestedAction() {
    let coding = ["fix the failing build", "Refactor the parser", "open a pull request for it",
                  "Add pagination to the users API", "Upgrade React to 19", "Write a Python scraper",
                  "Can you fix the typo in the README", "Bump the Node version in CI", "Make the tests pass",
                  "Port the CLI to TypeScript", "the login bug", "Add retry logic to the scraper and explain the approach",
                  // Codex review of fixes7: an imperative after a status clause wins over the earlier "are"/"is"/"why".
                  "The tests are failing; fix the bug", "The build is broken. Please fix it", "Tests are red so fix the parser",
                  "Why does the login page crash? Debug it", "The CI is failing, please update the dependencies",
                  "What changed in the API? Add a test for it.", "The README is outdated; rewrite it",
                  "Summarize the failure, then fix the failing tests", "The scraper times out, can you fix it?",
                  "Can you explain the failure, then fix the bug?",
                  "Explain this function and fix the bug",
                  "Explain the failure and then fix it",
                  "Describe the parser and then refactor it",
                  "Could you describe the failure and add a test?",
                  "Explain the bug then patch it",
                  "Summarize the test results and then debug the failure",
                  // Claude xrev2 finding 1: a why/what/where clause ends before "and"/"then" opens the imperative.
                  "Explain why the parser crashes and then fix it",
                  "Explain what went wrong and fix the bug",
                  "Explain why the tests fail, then fix them",
                  "Tell me why the build fails and fix it",
                  "Explain where the crash happens and fix it",
                  "Explain how the parser works and then add a test for it",
                  "Explain what this does and then refactor it",
                  "Explain why we add tests and then fix the bug",
                  "Explain how to build and test the parser, and fix the crash",
                  "Explain how to build the parser, then fix the bug",
                  // Fixes13: explanatory boundaries and adjacent coordination controls.
                  "Explain why we add tests, and fix the parser",
                  "Explain why we add tests, fix the parser",
                  "Explain why we add tests, then fix the parser",
                  "Explain why we add tests, and then fix the parser",
                  "Explain why we add tests, also fix the parser",
                  "Explain why we add tests, and also fix the parser",
                  "Explain why we add tests, plus fix the parser",
                  "Explain what we should add, then fix the parser",
                  "Explain what we should add, and fix the parser",
                  "Explain where we install Python packages, fix the parser",
                  "Explain how we build the parser, and then fix it",
                  "Explain when we run tests, also fix the parser",
                  "Explain which tests we run, plus fix the parser",
                  "Explain who can add tests, and fix the parser",
                  "Explain why we add tests, refactor the parser",
                  "Explain why we add tests, and fix it",
                  "Can you explain why we add tests, and fix the parser?",
                  "Could you explain what we should add, fix the parser?",
                  "Would you describe where we install Python packages, also fix the parser?",
                  "Will you explain when we run tests, plus fix the parser?",
                  "Can you explain how to build the parser, and fix it?",
                  "Explain why we add tests; fix the parser",
                  "Explain why we add tests; and fix the parser",
                  "Explain why we add tests; and then fix the parser",
                  "Explain why we add tests; also fix the parser",
                  "Explain why we add tests; plus fix the parser",
                  "Explain why we add tests. Also fix the parser",
                  "Explain why we add tests. Plus fix the parser",
                  "Explain why we add tests! Then fix the parser",
                  "Explain why we add tests? Fix the parser",
                  "Explain why we add tests\nThen fix the parser",
                  "Explain why the parser crashes plus fix it",
                  "Explain how to build the parser, plus fix it",
                  "Explain why we add tests and also why the parser crashes and fix it",
                  "Explain why we add tests and what went wrong and fix the parser",
                  "Explain why we add tests, and why the parser crashes and fix it",
                  "Explain why we also add tests, and fix the parser",
                  // Fixes14: comma-separated verb series inside an explanation and the commands that still follow them.
                  "Explain why we install, configure and run the server, and fix the parser",
                  "Explain why we build, test, and deploy the server, then fix the parser",
                  "Explain why we build, test and deploy the server, fix the parser",
                  "Can you explain why we install, configure and run the server, and fix the parser?",
                  "Explain why we build, test and deploy, then fix the parser",
                  "Explain why we install, configure and run the server; fix the parser",
                  "Explain why we install; configure and run the server",
                  "Explain why we build, test, and deploy; then fix the server",
                  "Explain why we install, fix the parser, and run tests",
                  "Explain why we add tests, and build, test and deploy the server",
                  "Explain why we test, fix the parser",
                  "Explain why we install, configure the server",
                  "Explain why we build, and deploy the server",
                  "Explain why we add, then fix the parser",
                  "Explain why we build and then deploy the server",
                  "Build, test and deploy the server",
                  "Install, configure, and run the server",
                  "Explain the result, then build, test and deploy the server",
                  "Explain why the parser crashes, also fix it",
                  "Explain why the parser crashes; also fix it",
                  // Fixes15: noun homographs and completed series must not hide commands.
                  "Explain the build, refactor and test the parser",
                  "Explain the test, refactor and test the parser",
                  "Explain the run, refactor and test the parser",
                  "Explain the fix, refactor and test the parser",
                  "Explain the deploy, refactor and test the parser",
                  "Explain a clean build, refactor and test the parser",
                  "Explain the unit test, refactor and deploy the server",
                  "Explain our nightly run, refactor and test the parser",
                  "Explain this quick fix, refactor and test the parser",
                  "Explain their latest deploy, refactor and test the parser",
                  "Can you explain the build, refactor and test the parser?",
                  "Could you describe the unit test, refactor and deploy the server?",
                  "Explain why we run the build, refactor and test the parser",
                  "Explain why we run the unit test, refactor and deploy the server",
                  "Explain why we test the run, refactor and test the parser",
                  "Explain why we deploy the fix, refactor and test the parser",
                  "Explain why we test the deploy, refactor and test the parser",
                  "Explain why we fix the build, refactor and deploy the server",
                  "Explain why the build, refactor and test the parser",
                  "Explain why the unit test, refactor and deploy the server",
                  "Explain how to run the build, refactor and test the parser",
                  "Explain why we install, configure and run, fix and test the parser",
                  "Explain why we build, test, and deploy, refactor and lint the parser",
                  "Explain why we build, test and deploy, refactor then lint the parser",
                  "Explain why we build, test or deploy, fix and test the parser",
                  "Explain why we build, test plus deploy, fix and test the parser",
                  "Explain why we build, test and also deploy, fix and test the parser",
                  "Explain why we build, test and then deploy, fix and test the parser",
                  "Explain why we lint, test, build and deploy, fix, refactor and test the parser",
                  "Explain why the developers build, test and deploy, fix and test the parser",
                  "Explain the reasons we install, configure and run, fix and test the parser",
                  "Can you explain why we install, configure and run, fix and test the parser?",
                  "Explain why we install, configure and run, and fix and test the parser",
                  "Explain why we install, configure and run, then fix and test the parser",
                  "Explain why we install, configure and run; fix and test the parser",
                  "Explain why we install, configure and run the server, fix and test the parser",
                  "Explain how to build, test and deploy, refactor and lint the parser",
                  "Explain how to build, test and deploy, fix the parser",
                  "Explain the build, fix and test the parser",
                  "Explain the deploy, configure and run the server",
                  "Explain the build, fix the parser",
                  // Fixes16: a determiner and modifiers before a homograph make a noun object.
                  "Explain why the nightly build, refactor and test the parser",
                  "Explain why our nightly build, refactor and test the parser",
                  "Explain why the slow test, fix and deploy the server",
                  "Explain why the previous build, refactor and test the parser",
                  "Explain why a clean build, refactor and test the parser",
                  "Explain why their latest deploy, fix and test the parser",
                  "Explain why this quick fix, refactor and test the parser",
                  "Explain why the slow unit test, refactor and deploy the server",
                  "Explain why our nightly smoke run, fix and test the parser",
                  "Explain why our team's nightly build, refactor and test the parser",
                  "Explain what the nightly build, refactor and test the parser",
                  "Explain how the slow test, fix and deploy the server",
                  "Can you explain why the nightly build, refactor and test the parser?",
                  "Explain why the nightly build, and refactor and test the parser",
                  "Explain why the nightly build, then fix the parser"]
    let general = ["Explain the result", "write the changelog", "summarize the meeting", "Explain this function",
                   "Describe how the users API works", "Summarize the test results", "What does this script do?",
                   "Write a blog post about Python", "Build a presentation for the board", "Draft the release notes",
                   "Review the pull request and list concerns", "How do I fix the build?",
                   "How do I add tests, then fix the build?", "The tests are failing; explain why",
                   "The build is broken. Please write a summary for the team", "What does the parser do? Describe it",
                   "The meeting notes are messy; clean them up",
                   "Explain how to build and test the parser",
                   "Describe how to add and remove a Python package",
                   "Can you explain how to build and then test the parser?",
                   // Claude xrev2 finding 1: "how to V1 and V2" and the explained clause's own coordinated verbs stay
                   // inside the explanation.
                   "Explain why we add tests and remove Python packages",
                   "Explain what we should add and remove in the package",
                   "Explain how to install the package and configure the database",
                   // Fixes13: explanatory boundaries and adjacent coordination controls.
                   "Explain why we add tests and also remove Python packages",
                   "Explain why we add tests plus remove Python packages",
                   "Explain where we install and remove Python packages",
                   "Explain when we add tests and remove Python packages",
                   "Explain how we build and test the parser",
                   "Explain who can add tests and remove Python packages",
                   "Explain which tests we add and remove",
                   "Explain why we add tests, and why we remove Python packages",
                   "Explain why we add tests, and how to remove Python packages",
                   "Explain why we add tests, and they remove Python packages",
                   "Explain why we add tests, and describe the parser",
                   "Explain why we add tests, and then explain how to fix the parser",
                   "Explain why we add tests; also describe the parser",
                   "Explain why we add tests. Plus explain how to fix the parser",
                   "Explain why we also add tests and remove Python packages",
                   "Explain why the parser crashes also fix it",
                   "Explain why they also fix the parser",
                   "Why do we add tests, and fix the parser?",
                   "What should we add, then remove in the Python package?",
                   "Where do we install Python packages, and run tests?",
                   "When do we add tests, plus fix the parser?",
                   "Who can add tests, and also fix the parser?",
                   "Which tests should we add, and remove?",
                   "Can you explain why we add tests, and how to fix the parser?",
                   "Explain how to build and also test the parser",
                   "Explain how to build and then test the parser",
                   "Explain how to build plus test the parser",
                   "Explain why we add tests, and write a summary",
                   "Explain why we add tests, plus write a summary",
                   "Explain why we add tests; also write a summary",
                   "Explain why we add tests. Then build a presentation",
                   "Can you explain why we add tests, and write a summary?",
                   "Explain why we also add tests plus remove Python packages",
                   "Explain how to also build and then test the parser",
                   "Explain how to build plus then test the parser",
                   // Fixes14: comma-separated verb series inside an explanation and the commands that still follow them.
                   "Explain why we install, configure and run the server",
                   "Can you explain why we install, configure and run the server?",
                   "Explain why we build, test, and deploy the server",
                   "Explain why we build, test, deploy the server",
                   "Explain why we lint, test, build and deploy the server",
                   "Explain why we lint, test, build, and deploy the server",
                   "Explain why we build, test or deploy the server",
                   "Explain why we build, test and also deploy the server",
                   "Explain why we refactor, test and deploy the parser",
                   "Explain why we build, test, and then deploy the server",
                   "Explain why we build, test and then deploy the server",
                   "Explain why we install, configure, and then run the server",
                   "Explain why we build, test, deploy, then release the server",
                   "Explain why we build, test and deploy it",
                   "Explain why we install and configure the server",
                   "Explain how we build, test and deploy the server",
                   "Explain where we install, configure and run the server",
                   "Describe when we build, test, and deploy the server",
                   "Explain who can build, test and deploy the server",
                   "Explain what we build, test and deploy on the server",
                   "Explain what we should add, fix and remove in the package",
                   "Explain which tests we write, run and fix in the parser",
                   "Explain the reasons we install, configure and run the server",
                   "Explain why the developers build, test and deploy the server",
                   "Explain how to build, test and deploy the server",
                   "Explain how to build, test, and then deploy the server",
                   "Could you explain why we build, test, and deploy the server?",
                   "Would you describe how we install, configure and run the server?",
                   "Can you explain why we lint, test, build and deploy the server?",
                   "Why do we build, test and deploy the server?",
                   "How do we install, configure, and run the server?",
                   "Explain why we build, test, and deploy the server; also describe the parser",
                   "Explain why we build, test and deploy the server, and write a summary",
                   "Explain why the developers also fix the parser",
                   // Fixes15: noun homographs and completed series must not hide commands.
                   "Explain why the developers test, build and deploy the server",
                   "Explain why the developers run, test and deploy the server",
                   "Explain why the developers fix, test and deploy the server",
                   "Explain why the developers deploy, configure and run the server",
                   "Explain why we also install, configure and run the server",
                   "Explain how to also build, test and deploy the server",
                   "Explain why we build, test and deploy, and why we install, configure and run the server",
                   "Explain the build",
                   "Explain the test",
                   "Explain the run",
                   "Explain the fix",
                   "Explain the deploy",
                   "Explain the build, write and update the summary",
                   "Explain why we install, configure and run, write and update the summary",
                   "Why do we install, configure and run, fix and test the parser?",
                   // Fixes16: modified nouns without commands and plural noun subjects stay general.
                   "Explain why the nightly build fails",
                   "Explain why our nightly build fails",
                   "Explain why the slow test times out",
                   "Explain what the slow unit test does",
                   "Explain how the nightly build works",
                   "Explain how the nightly build, test and deploy steps work",
                   "Explain why the nightly build, write and update the summary",
                   "Why does the nightly build fail?",
                   "Explain why the senior developers build, test and deploy the server",
                   "Explain why our senior developers fix, test and deploy the server",
                   "Explain why the team members build, test and deploy the server",
                   "Explain why the developers often build, test and deploy the server",
                   "Explain why the developers also build, test and deploy the server"]
    for phrase in coding {
        #expect(GoalProtocol.looksLikeCoding(phrase), "expected coding: \(phrase)")
    }
    for phrase in general {
        #expect(!GoalProtocol.looksLikeCoding(phrase), "expected general: \(phrase)")
    }
    let explanation = GoalRun(text: "Explain this function", maxRounds: 2, startedAt: Date(), maxDuration: 60)
    #expect(!explanation.requiresCodingEvidence)
    #expect(explanation.accepts(GoalEvidence(), reply: "It parses the header and returns the fields."))
    let upgrade = GoalRun(text: "Upgrade React to 19", maxRounds: 2, startedAt: Date(), maxDuration: 60)
    #expect(upgrade.requiresCodingEvidence)
    #expect(!upgrade.accepts(GoalEvidence(), reply: "Upgraded."))
}

// Cross-review finding 8: a plain /goal whose text changes code is held to the coding evidence contract; --general opts out.
@Test func codingLikeGoalsRequireEvidenceUnlessMarkedGeneral() {
    #expect(GoalProtocol.looksLikeCoding("fix the failing build") && GoalProtocol.looksLikeCoding("Refactor the parser") && GoalProtocol.looksLikeCoding("open a pull request for it"))
    #expect(!GoalProtocol.looksLikeCoding("Explain the result") && !GoalProtocol.looksLikeCoding("write the changelog") && !GoalProtocol.looksLikeCoding("summarize the meeting"))
    var goal = GoalRun(text: "fix the failing build", maxRounds: 2, startedAt: Date(), maxDuration: 60)
    #expect(goal.codingEvidence == nil && goal.requiresCodingEvidence)
    #expect(!goal.accepts(GoalEvidence(deliverable: "done in chat"), reply: "Fixed it."))
    #expect(goal.accepts(GoalEvidence(testsPassed: true, report: "/r"), reply: ""))
    #expect(GoalProtocol.firstTurn(goal).contains("\"commit\"") && GoalProtocol.evidenceRequest(goal, evidence: GoalEvidence()).hasPrefix("Your done block"))
    goal.codingEvidence = false
    #expect(!goal.requiresCodingEvidence && goal.accepts(GoalEvidence(), reply: "Fixed it."))
    #expect(goal.doneDetail(GoalEvidence()).hasPrefix("Unverified (general goal): "))
    let general = GoalRun(text: "write the changelog", maxRounds: 2, startedAt: Date(), maxDuration: 60)
    #expect(!general.requiresCodingEvidence && !general.doneDetail(GoalEvidence()).hasPrefix("Unverified"))
}

@MainActor @Test func aPlainCodingLikeGoalIsSentBackWithoutEvidenceAndGeneralOptsOut() async throws {
    let backend = ScriptedTurnBackend(); let (store, bot) = goalStore(backend)
    #expect(store.submitComposer(text: "/goal fix the failing build"))
    try await waitUntil { await backend.streamCount == 1 }
    #expect(store.goal(in: bot)?.codingEvidence == nil && store.goal(in: bot)?.requiresCodingEvidence == true)
    #expect(bot.messages.first { $0.role == .user }?.content.contains("\"commit\"") == true, "the coding protocol is sent")
    await finish(backend, bareDoneReply)
    try await waitUntil { await backend.streamCount == 2 }
    let card = try #require(bot.messages.last { $0.presentation == .automation })
    #expect(card.content == "Done claimed without evidence" && card.metadata[AutomationKey.card] == "goalUnverified")
    await finish(backend, doneReply)
    try await waitUntil { store.goal(in: bot)?.state == .done }
    #expect(bot.messages.last?.metadata[AutomationKey.detail]?.contains("not verified by SwarmHub: commit abc1234") == true)

    let (general, generalBot) = goalStore(backend)
    #expect(general.submitComposer(text: "/goal --general fix the failing build"))
    try await waitUntil { await backend.streamCount == 3 }
    #expect(general.goal(in: generalBot)?.text == "fix the failing build" && general.goal(in: generalBot)?.codingEvidence == false)
    await finish(backend, bareDoneReply)
    try await waitUntil { general.goal(in: generalBot)?.state == .done }
    #expect(generalBot.messages.last?.metadata[AutomationKey.detail]?.contains("Unverified (general goal)") == true)
}

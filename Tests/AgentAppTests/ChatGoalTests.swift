import Foundation
import Testing
@testable import AgentApp

/// Every reply, approval wait and interrupt acknowledgement is controlled by the test.
private actor GoalBackend: AgentBackend {
    nonisolated let kind = BackendKind.herdr
    private(set) var requests: [AgentRequest] = []
    private var streams: [AsyncThrowingStream<AgentEvent, Error>.Continuation] = []
    private var blocker: String?
    private var interrupt: CheckedContinuation<StopOutcome, Never>?
    var stopping: Bool { interrupt != nil }

    func setBlocker(_ value: String?) { blocker = value }
    func goalBlocker(sessionID: String) async throws -> String? { blocker }
    func testConnection() async throws -> String { "fake" }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func stopTarget(sessionID: String) async throws -> StopTarget { .serverRun(sessionID) }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        await withCheckedContinuation { interrupt = $0 }
    }
    func acknowledgeStop() {
        interrupt?.resume(returning: .requested)
        interrupt = nil
    }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        requests.append(request)
        streams.append(continuation)
        return stream
    }
    func emit(_ event: AgentEvent, step: Int) { streams[step].yield(event) }
    func end(_ step: Int) {
        streams[step].yield(.completed)
        streams[step].finish()
    }
    func report(_ outcome: ChatGoal.Report.Outcome, _ evidence: String, for attempt: UUID, step: Int) throws {
        let data = try JSONEncoder().encode(ChatGoal.Report(iteration: attempt, outcome: outcome, evidence: evidence))
        emit(.replace(String(decoding: data, as: UTF8.self)), step: step)
        end(step)
    }
}

@MainActor private func goalStore(_ backend: GoalBackend, url: URL = temporaryStore()) -> AppStore {
    AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend },
             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
}

@MainActor private func addGoalBot(_ store: AppStore, _ name: String) -> Bot {
    let bot = Bot(name: name, backend: .herdr)
    store.bots.append(bot)
    store.open(bot, remember: false)
    return bot
}

struct ChatGoalTests {
    @MainActor @Test func sessionSpendGuardChecksIdentityAndFreshUsageAfterRestore() throws {
        let store = goalStore(GoalBackend())
        let bot = addGoalBot(store, "Budget")
        var goal = ChatGoal(objective: "Review", destination: store.goalDestination(for: bot))
        goal.budgetUSD = 2
        let agent = HerdrClient.AgentRef(address: "s", createdMs: 1)
        let start = ChatGoal.SpendReading(core: "qa", agent: agent, tokens: 100, usd: 1.5)
        let unknown = goal.permitsNextStep(spend: nil)
        #expect(!unknown && goal.state == .waiting)
        goal.resume()
        let allowed = goal.permitsNextStep(spend: start)
        #expect(allowed)
        var restored = try JSONDecoder().decode(ChatGoal.self, from: JSONEncoder().encode(goal))
        let stale = restored.permitsNextStep(spend: start)
        #expect(!stale && restored.state == .waiting)
        restored.resume()
        let changed = restored.permitsNextStep(spend: .init(core: "another", agent: agent, tokens: 101, usd: 1.6))
        #expect(!changed && restored.state == .waiting)
        restored.resume()
        let capped = restored.permitsNextStep(spend: .init(core: "qa", agent: agent, tokens: 125, usd: 2))
        #expect(!capped && restored.state == .stopped)
    }

    @Test @MainActor func cappedGoalStopsAtItsLastStepAndKeepsTheResult() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        #expect(store.handleGoalCommand(.start("Check the fixture", stepLimit: 1), in: bot) == nil)
        try await waitUntil { await backend.requests.count == 1 }
        let token = try #require(bot.goal?.attempt)
        #expect(store.handleGoalCommand(.start("Replace it", stepLimit: 5), in: bot) != nil)
        try await backend.report(.progress, "Fixture inspected", for: token, step: 0)
        try await waitUntil { bot.goal?.state == .stopped }
        #expect(bot.goal?.detail.contains("Fixture inspected") == true)
        #expect(store.handleGoalCommand(.status, in: bot)?.contains("Steps: 1 of 1") == true)
        let goal = try #require(bot.goal)
        let restored = try JSONDecoder().decode(ChatGoal.self, from: JSONEncoder().encode(goal))
        #expect(restored.stepLimit == 1)
        store.recoverGoals()
        store.sendQueuedNextMessage()
        #expect(await backend.requests.count == 1)
    }

    @Test @MainActor func recoveredGoalAtLimitStartsNoExtraTurnAndOldGoalsRemainUnlimited() throws {
        let store = goalStore(GoalBackend())
        let bot = addGoalBot(store, "Owner")
        var capped = ChatGoal(objective: "Inspect", destination: store.goalDestination(for: bot), stepLimit: 1)
        let token = capped.begin()
        capped.finish(.init(iteration: token, outcome: .complete, evidence: "Checked the last item"))
        #expect(capped.state == .completed)
        capped.state = .queued
        bot.goal = capped
        store.recoverGoals()
        store.sendQueuedNextMessage()
        #expect(bot.goal?.state == .stopped && bot.goal?.iteration == 1)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(capped)) as? [String: Any])
        legacy.removeValue(forKey: "stepLimit")
        var restored = try JSONDecoder().decode(ChatGoal.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.stepLimit == nil)
        let reachedLimit = restored.stopAtStepLimit()
        #expect(!reachedLimit)
    }

    @Test @MainActor func goalProgressContinuesInOriginalChatAndCompletionNeedsEvidence() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let other = addGoalBot(store, "Other"), bot = addGoalBot(store, "Owner")
        #expect(store.handleGoalCommand(.start("Verify the fixture"), in: bot) == nil)
        let first = try #require(bot.goal?.attempt)
        #expect(store.handleGoalCommand(.start("clarification"), in: bot)?.contains("cannot take live guidance") == true)
        #expect(!bot.messages.contains { $0.content == "clarification" })
        #expect(store.handleGoalCommand(.status, in: bot)?.contains("Verify the fixture") == true)
        store.open(other, remember: false)
        try await waitUntil { await backend.requests.count == 1 }
        let request = try #require(await backend.requests.first)
        let wire = try #require(request.messages.last?.content)
        #expect(wire.contains(first.uuidString) && wire.contains("Verify the fixture"))
        #expect(!wire.hasPrefix("/goal"))
        await backend.emit(.token("partial progress"), step: 0)
        store.sendQueuedNextMessage()
        #expect(bot.goal?.attempt == first)
        try await backend.report(.progress, "Fixture generated", for: first, step: 0)
        try await waitUntil { await backend.requests.count == 2 }
        let second = try #require(bot.goal?.attempt)
        #expect(second != first)
        let requests = await backend.requests
        #expect(requests.allSatisfy { $0.sessionID == bot.id.uuidString })
        #expect(requests.last?.messages.last?.content.contains("Fixture generated") == true)
        try await backend.report(.complete, "All three fixture checks passed", for: second, step: 1)
        try await waitUntil { store.isIdle(bot) }
        store.sendQueuedNextMessage()
        #expect(bot.goal?.state == .completed)
        #expect(bot.goal?.detail == "All three fixture checks passed")
        #expect(bot.goal?.iteration == 2)
        #expect(bot.messages.compactMap { $0.metadata[GoalKey.outcome] } == ["progress", "complete"])
        #expect(other.goal == nil && other.messages.isEmpty)
        #expect(await backend.requests.count == 2)
    }

    @Test @MainActor func goalBlocksForApprovalAndUserInputUntilExplicitResume() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Reviewer")
        await backend.setBlocker("Review the pending workspace approval.")
        #expect(store.handleGoalCommand(.start("Review the fixture"), in: bot) == nil)
        try await waitUntil { bot.goal?.state == .waiting }
        #expect(await backend.requests.isEmpty)
        #expect(bot.goal?.detail.contains("approval") == true)
        await backend.setBlocker(nil)
        store.resumeGoal(in: bot)
        try await waitUntil { await backend.requests.count == 1 }
        let attempt = try #require(bot.goal?.attempt)
        try await backend.report(.blocked, "Which fixture should I use?", for: attempt, step: 0)
        try await waitUntil { bot.goal?.state == .waiting }
        store.sendQueuedNextMessage()
        #expect(await backend.requests.count == 1)
        #expect(bot.goal?.detail == "Which fixture should I use?")
        store.resumeGoal(in: bot)
        try await waitUntil { await backend.requests.count == 2 }
        try await backend.report(.complete, "Stale evidence", for: attempt, step: 1)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.state == .waiting)
        #expect(bot.goal?.detail.contains("no confirmed goal outcome") == true)
    }

    @Test @MainActor func goalStopFencesLateRepliesAndReplacementDuringRemoteInterrupt() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        #expect(store.handleGoalCommand(.start("Original goal"), in: bot) == nil)
        try await waitUntil { await backend.requests.count == 1 }
        let oldAttempt = try #require(bot.goal?.attempt)
        #expect(store.handleGoalCommand(.stop, in: bot) == nil)
        try await waitUntil { await backend.stopping }
        try await backend.report(.progress, "Late progress", for: oldAttempt, step: 0)
        #expect(bot.goal?.state == .stopped)
        #expect(store.handleGoalCommand(.start("Replacement"), in: bot) == nil)
        store.sendQueuedNextMessage()
        #expect(bot.goal?.state == .queued)
        #expect(await backend.requests.count == 1)
        await backend.acknowledgeStop()
        try await waitUntil { await backend.requests.count == 2 }
        let next = try #require(bot.goal?.attempt)
        try await backend.report(.complete, "Replacement verified", for: next, step: 1)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.detail == "Replacement verified")
        #expect(bot.goal?.iteration == 1)
    }

    @Test @MainActor func restartResumesUndispatchedGoalOnceAndHoldsUncertainIteration() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Pending"), busy = addGoalBot(store, "Busy")
        store.open(bot, remember: false)
        store.turnLimits = TurnLimits(total: 1, perConnection: 1)
        let slot = store.beginTurn(in: busy, bot: busy, assistant: nil)
        #expect(store.handleGoalCommand(.start("Count the entries"), in: bot) == nil)
        #expect(bot.goal?.state == .queued)
        let secondBackend = GoalBackend(), reopened = goalStore(secondBackend, url: store.fileURL)
        let restored = try #require(reopened.bots.first { $0.id == bot.id })
        #expect(restored.goal?.id == bot.goal?.id)
        reopened.recoverGoals()
        reopened.sendQueuedNextMessage()
        reopened.recoverGoals()
        reopened.sendQueuedNextMessage()
        try await waitUntil { await secondBackend.requests.count == 1 }

        // The saved claim precedes delivery. Simulate relaunch from those exact bytes.
        let snapshot = temporaryStore()
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.fileURL, to: snapshot)
        let thirdBackend = GoalBackend(), interrupted = goalStore(thirdBackend, url: snapshot)
        let uncertain = try #require(interrupted.bots.first { $0.id == bot.id })
        interrupted.recoverGoals()
        interrupted.sendQueuedNextMessage()
        #expect(uncertain.goal?.state == .waiting)
        #expect(uncertain.goal?.objective == "Count the entries")
        #expect(await thirdBackend.requests.isEmpty)
        #expect(await backend.requests.isEmpty)

        // Release the synthetic capacity constraint and retire the fake stream.
        store.endTurn(slot.token)
        await secondBackend.end(0)
        try await waitUntil { reopened.isIdle(restored) }
    }

    @Test @MainActor func goalRoutingRejectsGroupSampleArchiveAndStaleComposer() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Bot")
        let group = GroupChat(name: "Team", memberIDs: [bot.id])
        store.groups = [group]
        store.open(group, remember: false)
        let unsupported: [any Conversation] = [group, bot]
        for chat in unsupported {
            #expect(store.handleGoalCommand(.start("Wrong destination"), in: chat) != nil)
        }
        store.open(bot, remember: false)
        bot.archivedMembers = ["Former member"]
        #expect(store.handleGoalCommand(.start("Archive"), in: bot) != nil)
        bot.archivedMembers = nil
        bot.backend = .mock
        #expect(store.handleGoalCommand(.start("Sample"), in: bot) != nil)
        #expect(bot.goal == nil && group.messages.isEmpty)
        bot.backend = .herdr
        #expect(store.send(text: "Please keep going until my goal is complete"))
        try await waitUntil { await backend.requests.count == 1 }
        await backend.end(0)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal == nil)
    }

    @Test @MainActor func queuedGoalStopLeavesOrdinaryTurnAloneAndEarlyStopNeverSends() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        #expect(store.send(text: "One ordinary message"))
        try await waitUntil { await backend.requests.count == 1 }
        #expect(store.handleGoalCommand(.start("Queued goal"), in: bot) == nil)
        #expect(bot.goal?.state == .queued)
        #expect(store.handleGoalCommand(.stop, in: bot) == nil)
        #expect(store.isStreaming(in: bot))
        let stopping = await backend.stopping
        #expect(!stopping)
        await backend.end(0)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.iteration == 0)
        #expect(store.handleGoalCommand(.start("Stop before delivery"), in: bot) == nil)
        store.stop(bot)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.state == .stopped)
        #expect(await backend.requests.count == 1)
    }

    @Test @MainActor func olderOrdinaryInterruptCannotReachTheFirstGoalStep() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        #expect(store.send(text: "Ordinary turn"))
        try await waitUntil { await backend.requests.count == 1 }
        store.stop(bot)
        try await waitUntil { await backend.stopping }
        try await waitUntil { store.isIdle(bot) }
        #expect(store.handleGoalCommand(.start("Next goal"), in: bot) == nil)
        #expect(bot.goal?.state == .queued)
        #expect(await backend.requests.count == 1)
        await backend.acknowledgeStop()
        try await waitUntil { await backend.requests.count == 2 }
        let attempt = try #require(bot.goal?.attempt)
        try await backend.report(.complete, "Checked the result", for: attempt, step: 1)
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.state == .completed)
    }

    @Test @MainActor func changedDestinationAndFailedSavePreventDelivery() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        let slot = store.beginTurn(in: bot, bot: bot, assistant: nil)
        #expect(store.handleGoalCommand(.start("Queued work"), in: bot) == nil)
        bot.sessionID = "different conversation"
        store.endTurn(slot.token)
        store.sendQueuedNextMessage()
        #expect(bot.goal?.state == .waiting)
        store.resumeGoal(in: bot)
        #expect(store.isIdle(bot))
        #expect(store.handleGoalCommand(.stop, in: bot) == nil)
        try Data("changed by another writer".utf8).write(to: store.fileURL)
        #expect(store.handleGoalCommand(.start("Unsaved work"), in: bot) != nil)
        #expect(bot.goal?.state == .stopped)
        #expect(await backend.requests.isEmpty)
    }

    @Test @MainActor func goalBoundsFailedAndRepeatedStepsAndRequiresCompletionEvidence() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Owner")
        #expect(store.handleGoalCommand(.start("Verify entries"), in: bot) == nil)
        for (index, outcome) in [ChatGoal.Report.Outcome.failed, .noProgress].enumerated() {
            try await waitUntil { await backend.requests.count == index + 1 }
            let token = try #require(bot.goal?.attempt)
            try await backend.report(outcome, "Fixture unavailable", for: token, step: index)
        }
        try await waitUntil { store.isIdle(bot) }
        #expect(bot.goal?.state == .waiting)
        #expect(bot.goal?.iteration == 2)
        var goal = try #require(bot.goal)
        goal.resume()
        for _ in 0..<3 {
            let attempt = goal.begin()
            goal.finish(.init(iteration: attempt, outcome: .progress, evidence: "The same observation"))
        }
        #expect(goal.state == .waiting)
        goal.resume()
        for index in 0..<40 {
            let attempt = goal.begin()
            goal.finish(.init(iteration: attempt, outcome: .progress, evidence: "Verified item \(index)"))
        }
        #expect(goal.state == .queued)
        let token = UUID()
        let line = #"{"iteration":"\#(token.uuidString)","outcome":"complete","evidence":"  "}"#
        #expect(ChatGoal.Report.read(line, for: token) == nil)
        #expect(ChatGoal.Report.read("I think we are done.", for: token) == nil)
    }
}

@MainActor @Test func deliveredGoalGuidanceSurvivesTheEndOfItsIteration() async throws {
    let backend = ScriptedTurnBackend()
    let (store, bot) = steerStore(backend)
    #expect(store.handleGoalCommand(.start("Inspect the archive fixture"), in: bot) == nil)
    let attempt = try #require(bot.goal?.attempt)
    try await waitUntil { store.canSteer(in: bot) }
    await backend.holdSteers()
    let file = ChatAttachment(id: UUID(), kind: .text, name: "manifest.txt", mimeType: "text/plain", byteCount: 3, text: "one")
    #expect(store.handleGoalCommand(.start("Include the manifest"), in: bot, attachments: [file]) == nil)
    try await backend.calls.wait { $0.contains("steer-held:Include the manifest") }
    let report = ChatGoal.Report(iteration: attempt, outcome: .progress, evidence: "Fixture inspected")
    let data = try JSONEncoder().encode(report)
    await backend.emit(.replace(String(decoding: data, as: UTF8.self)), .completed)
    await backend.end()
    try await waitUntil { !store.canSteer(in: bot) }
    #expect(await backend.streamCount == 1)
    await backend.releaseSteers()
    try await waitUntil { await backend.streamCount == 2 }
    #expect(bot.goal?.objective.contains("Include the manifest") == true)
    #expect(bot.goal?.objective.contains("manifest.txt") == true)
    #expect((await backend.calls.all).last?.contains("Include the manifest") == true)
    #expect(store.handleGoalCommand(.stop, in: bot) == nil)
    await backend.end()
    try await waitUntil { store.isIdle(bot) }
    #expect(bot.goal?.state == .stopped && store.turns.nextMessages.isEmpty)
}

extension ChatGoalTests {
    @MainActor @Test func perGoalCeilingStartsAbovePriorSpendAndStopsBeforeAnotherPaidStep() async throws {
        let backend = GoalBackend(), store = goalStore(backend)
        let bot = addGoalBot(store, "Budget")
        let agent = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        let meter = AwaitableLog<Double>()
        meter.append(2.50)
        let http = MockHTTPProtocol.serve { req in
            guard req.url?.path == "/api/workspace" else { return (404, [:]) }
            let readings = meter.all
            return (200, ["core": "budget-qa", "templates": [], "agents": [
                ["name": agent, "address": "t1", "created_ms": 10, "state": "live",
                 "session_usage": ["total_tokens": readings.count * 200, "opencode_cost_usd": readings.last ?? 0]]]])
        }
        store.saveHerdrServer(.init(id: HerdrServer.defaultID, name: "Budget QA", kind: .address, address: "http://" + http.host), token: "sample")
        store.herdrClientSetup = { $0.session = http.session }
        let command = try #require(SlashCommand.parse("/goal --goal-budget 0.20 inspect"))
        #expect(store.handleGoalCommand(command, in: bot) == nil)
        try await waitUntil { await backend.requests.count == 1 }
        let first = try #require(bot.goal?.attempt)
        #expect(bot.goal?.stepSpending?.chargedUSD == 0)
        meter.append(2.60)
        try await backend.report(.progress, "First fixture checked", for: first, step: 0)
        try await waitUntil { await backend.requests.count == 2 }
        let second = try #require(bot.goal?.attempt)
        #expect(bot.goal?.stepSpending?.chargedUSD == Decimal(string: "0.10"))
        meter.append(2.70)
        try await backend.report(.progress, "Second fixture checked", for: second, step: 1)
        try await waitUntil { bot.goal?.state == .stopped }
        #expect(await backend.requests.count == 2)
        #expect(bot.goal?.stepSpending?.chargedUSD == Decimal(string: "0.20"))
        #expect(bot.goal?.stepSpending?.pending == nil)
    }

    @MainActor @Test func perGoalMeterRestoresAnUnpricedStepOnceAndSkipsSpendBetweenSteps() throws {
        let store = goalStore(GoalBackend()), bot = addGoalBot(store, "Owner")
        var goal = ChatGoal(objective: "Check two steps", destination: store.goalDestination(for: bot))
        goal.budgetUSD = 1
        goal.stepSpending = .init()
        func reading(_ tokens: Int64, _ usd: Double, created: UInt64 = 11) -> ChatGoal.SpendReading {
            .init(core: "qa", agent: .init(address: "t2", createdMs: created), tokens: tokens, usd: usd)
        }
        let allowedStart = goal.permitsNextStep(spend: reading(100, 3))
        #expect(allowedStart)
        let attempt = goal.begin()
        var restored = try JSONDecoder().decode(ChatGoal.self, from: JSONEncoder().encode(goal))
        #expect(restored.stepSpending?.attempt == attempt)
        let staleAllowed = restored.permitsNextStep(spend: reading(100, 3))
        #expect(!staleAllowed)
        let replacedCharged = restored.recordStepCost(reading(200, 3.5, created: 12))
        #expect(!replacedCharged)
        let charged = restored.recordStepCost(reading(200, 3.5))
        #expect(charged)
        let chargedAgain = restored.recordStepCost(reading(200, 3.5))
        #expect(!chargedAgain)
        restored.resume()
        let allowedNext = restored.permitsNextStep(spend: reading(300, 6))
        #expect(allowedNext)
        let chargedSecond = restored.recordStepCost(reading(350, 6.5))
        #expect(chargedSecond)
        let allowedThird = restored.permitsNextStep(spend: reading(350, 6.5))
        #expect(!allowedThird)
        #expect(restored.stepSpending?.chargedUSD == 1 && restored.state == .stopped)
    }
}

import AppKit
import Foundation
import Testing
@testable import AgentApp

@MainActor struct WorkflowTests {
    func store(_ backend: TestBackend, url: URL = temporaryStore()) -> AppStore {
        AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }
    func paused(_ group: GroupChat, coordinator: UUID, tasks: [WorkflowTask], limit: Int = 50_000) -> Workflow {
        Workflow(id: UUID(), groupID: group.id, coordinatorID: coordinator, request: "Research", state: .paused, tasks: tasks, budget: .init(id: UUID(), tokenLimit: limit))
    }

    @Test func workflowRunsDependenciesAndProjectsOneConsolidatedResult() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .response("Specialist result"))
        let url = temporaryStore(); let store = store(backend, url: url)
        let a = Bot(name: "Research", backend: .hermes), b = Bot(name: "Analysis", backend: .hermes); store.bots = [a, b]
        let group = GroupChat(name: "Project", memberIDs: [a.id, b.id]); store.groups = [group]
        let workflow = paused(group, coordinator: a.id, tasks: [
            .init(id: "research-a", botID: a.id, instructions: "Research A", expectedOutput: "Evidence", dependencies: []),
            .init(id: "research-b", botID: b.id, instructions: "Research B", expectedOutput: "Evidence", dependencies: []),
            .init(id: "synthesis", botID: a.id, instructions: "Synthesize", expectedOutput: "One answer", dependencies: ["research-a", "research-b"])])
        try store.saveWorkflow(workflow)
        store.resumeWorkflow(workflow.id)
        try await waitUntil { store.workflows[workflow.id]?.state == .completed }
        let done = try #require(store.workflows[workflow.id])
        #expect(done.tasks.allSatisfy { $0.state == .completed && $0.resultArtifactID != nil } && done.budget.reserved == 0 && done.budget.spent > 0)
        #expect(group.messages.filter { $0.metadata["workflowID"] == workflow.id.uuidString }.map(\.content) == ["Specialist result"])
        // Each task ran in its own fresh session, never in the bot's chat.
        #expect(backend.calls.all.filter { $0.hasPrefix("create:") }.allSatisfy { $0.contains("agentapp_workflow_") })
        #expect(a.messages.isEmpty && b.messages.isEmpty && a.threads.count == 2 && b.threads.count == 1)
        let synthesisPrompt = try #require(a.threads.first { $0.id == done.tasks[2].threadID }?.messages.first?.content)
        #expect(synthesisPrompt.contains("Result of research-a:\nSpecialist result") && synthesisPrompt.contains("Result of research-b"))
        let artifactID = try #require(done.artifactID)
        #expect(String(decoding: try store.artifacts().read(artifactID, botID: b.id), as: UTF8.self) == "Specialist result")
        #expect(throws: (any Error).self) { try store.artifacts().read(artifactID, botID: UUID()) }
        let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(restored.workflows[workflow.id]?.state == .completed)
        #expect(restored.groups.first?.messages.filter { $0.metadata["workflowID"] == workflow.id.uuidString }.count == 1)
    }

    @Test func theCoordinatorsPlanWaitsForApprovalWithAFinalSynthesis() async throws {
        let a = Bot(name: "Lead", backend: .hermes), b = Bot(name: "Coder", backend: .hermes)
        let plan = """
        Here is the plan:
        ```json
        {"tasks": [{"id": "code", "botID": "\(b.id.uuidString)", "instructions": "Write it", "expectedOutput": "A patch", "dependencies": [], "role": "coding"},
                   {"id": "review", "botID": "\(a.id.uuidString)", "instructions": "Review it", "expectedOutput": "A verdict", "dependencies": ["code"], "role": "reviewer"}]}
        ```
        """
        let backend = TestBackend(transport: .nativeSessions, streamMode: .response(plan))
        let store = store(backend); store.bots = [a, b]
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id]); store.groups = [group]
        #expect(store.startWorkflow(text: "Ship the fix", group: group, coordinator: a))
        let id = try #require(store.workflows.keys.first)
        try await waitUntil { store.workflows[id]?.state == .paused }
        let workflow = try #require(store.workflows[id])
        #expect(workflow.error == nil && workflow.tasks.map(\.id) == ["code", "review", "synthesis"])
        #expect(workflow.tasks.map(\.role) == [.coding, .conversation, .conversation] && workflow.tasks[2].dependencies == ["code", "review"])
        #expect(workflow.stateLabel == "Waiting for your approval" && workflow.deadline == nil)
        #expect(backend.calls.all.filter { $0 == "send" }.count == 1, "nothing runs before approval")
    }

    @Test func anUnreadablePlanPausesWithTheReason() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .response("I would rather just do it."))
        let store = store(backend); let a = Bot(name: "Lead", backend: .hermes); store.bots = [a]
        let group = GroupChat(name: "Team", memberIDs: [a.id]); store.groups = [group]
        #expect(store.startWorkflow(text: "Plan", group: group, coordinator: a))
        let id = try #require(store.workflows.keys.first)
        try await waitUntil { store.workflows[id]?.state == .paused }
        #expect(store.workflows[id]?.tasks.isEmpty == true && store.workflows[id]?.error?.contains("did not return a plan") == true)
    }

    @Test func restartPausesRunningWorkAndRebuildsTheTaskThread() throws {
        let url = temporaryStore(); let store = store(TestBackend(transport: .nativeSessions), url: url)
        let bot = Bot(name: "Specialist", backend: .hermes); store.bots = [bot]
        let group = GroupChat(name: "Team", memberIDs: [bot.id]); store.groups = [group]; store.save()
        var budget = RunBudget(id: UUID(), tokenLimit: 8_000); try budget.reserve(1_000)
        let task = WorkflowTask(id: "review", botID: bot.id, instructions: "Review", expectedOutput: "Verdict", dependencies: [], state: .running, reservation: 1_000, replyID: UUID())
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: bot.id, request: "Review", state: .running, tasks: [task], budget: budget)
        // Crash boundary: the ledger has the running task, store.json never got its thread.
        try store.saveWorkflow(workflow)
        let restored = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(restored.workflows[workflow.id]?.state == .paused && restored.workflows[workflow.id]?.tasks.first?.state == .blocked)
        let thread = try #require(restored.bots.first?.threads.first)
        #expect(thread.id == task.threadID && thread.parentMessageID == workflow.id && restored.isWorkflowThread(thread))
        restored.resumeWorkflow(workflow.id)
        #expect(restored.workflows[workflow.id]?.state == .paused && restored.errorMessage?.contains("blocked") == true)
    }

    @Test func cancelStopsTheRunningTaskAndReleasesEveryReservation() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning)
        let store = store(backend); let bot = Bot(name: "Specialist", backend: .hermes); store.bots = [bot]
        let group = GroupChat(name: "Team", memberIDs: [bot.id]); store.groups = [group]
        let tasks = ["a", "b"].map { WorkflowTask(id: $0, botID: bot.id, instructions: "Work", expectedOutput: "Result", dependencies: []) }
        let workflow = paused(group, coordinator: bot.id, tasks: tasks, limit: 30_000)
        try store.saveWorkflow(workflow); store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.contains("send") }
        #expect((store.workflows[workflow.id]?.budget.reserved ?? 0) > 0)
        store.pauseWorkflow(workflow.id, cancel: true)
        try await waitUntil { !store.anyTurnRunning && store.workflows[workflow.id]?.budget.reserved == 0 }
        #expect(store.workflows[workflow.id]?.state == .cancelled)
        #expect(store.workflows[workflow.id]?.tasks.allSatisfy { $0.state == .cancelled } == true)
        #expect(backend.calls.all.filter { $0 == "send" }.count == 1)
    }

    @Test func cancelledPlanningCannotReviveTheWorkflow() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning)
        let store = store(backend); let bot = Bot(name: "Coordinator", backend: .hermes); store.bots = [bot]
        let group = GroupChat(name: "Team", memberIDs: [bot.id]); store.groups = [group]
        #expect(store.startWorkflow(text: "Plan work", group: group, coordinator: bot))
        try await backend.calls.wait { $0.contains("send") }
        let id = try #require(store.workflows.keys.first)
        store.pauseWorkflow(id, cancel: true)
        try await waitUntil { !store.anyTurnRunning }
        #expect(store.workflows[id]?.state == .cancelled && store.workflows[id]?.tasks.isEmpty == true)
    }

    @Test func theThirtyMinuteLimitStopsUnfinishedWork() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning)
        let store = store(backend); let bot = Bot(name: "Specialist", backend: .hermes); store.bots = [bot]
        let deadline = AwaitableLog<String>()
        store.workflowSleep = { _ in try await deadline.wait { $0.contains("passed") } }
        let group = GroupChat(name: "Team", memberIDs: [bot.id]); store.groups = [group]
        let workflow = paused(group, coordinator: bot.id, tasks: [.init(id: "a", botID: bot.id, instructions: "Work", expectedOutput: "Result", dependencies: [])])
        try store.saveWorkflow(workflow); store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.contains("send") }
        #expect(store.workflows[workflow.id]?.deadline != nil)
        deadline.append("passed")
        try await waitUntil { store.workflows[workflow.id]?.state == .cancelled && !store.anyTurnRunning }
        #expect(store.workflows[workflow.id]?.error?.contains("30-minute") == true)
    }

    @Test func aFinishedReplySettlesABlockedTaskOnceWithoutDoubleCounting() async throws {
        let store = store(TestBackend(transport: .nativeSessions))
        let bot = Bot(name: "Reviewer", backend: .hermes); store.bots = [bot]
        let group = GroupChat(name: "Team", memberIDs: [bot.id]); store.groups = [group]
        let user = ChatMessage(role: .user, content: "Review")
        let reply = ChatMessage(role: .assistant, content: "Complete", metadata: ["inputTokens": "30", "outputTokens": "10"], turnState: .incomplete)
        var budget = RunBudget(id: UUID(), tokenLimit: 8_000); budget.spent = 12
        let workflow = paused(group, coordinator: bot.id, tasks: [.init(id: "review", botID: bot.id, instructions: "Review", expectedOutput: "Verdict", dependencies: [], state: .blocked, chargedTokens: 12, replyID: reply.id)])
        var saved = workflow; saved.budget = budget
        try store.saveWorkflow(saved)
        bot.threads = [ChatThread(id: workflow.tasks[0].threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil, messages: [user, reply])]
        store.settleWorkflows()
        #expect(store.workflows[workflow.id]?.tasks.first?.state == .blocked, "an incomplete reply stays blocked")
        reply.turnState = .finished // Retry or the reconcile finished it
        await store.refreshWorkflowTask(workflow.id, taskID: "review")
        store.settleWorkflows()
        #expect(store.workflows[workflow.id]?.budget.spent == 40)
        #expect(store.workflows[workflow.id]?.tasks.first?.state == .completed && store.workflows[workflow.id]?.tasks.first?.resultArtifactID != nil)
    }

    @Test func reassignMovesOnlyCertainlyUnsentWorkAndRetiresTheOldThread() throws {
        let store = store(TestBackend(transport: .nativeSessions))
        let a = Bot(name: "A", backend: .hermes), b = Bot(name: "B", backend: .hermes); store.bots = [a, b]
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id]); store.groups = [group]
        let user = ChatMessage(role: .user, content: "Task")
        let reply = ChatMessage(role: .assistant, content: "", metadata: [TurnKey.ambiguous: "1"], turnState: .notSent)
        let workflow = paused(group, coordinator: a.id, tasks: [.init(id: "task", botID: a.id, instructions: "Work", expectedOutput: "Result", dependencies: [], state: .blocked, replyID: reply.id)])
        let thread = ChatThread(id: workflow.tasks[0].threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil, messages: [user, reply]); a.threads = [thread]
        try store.saveWorkflow(workflow)
        #expect(!store.reassignWorkflowTask(workflow.id, taskID: "task", botID: b.id), "the box may have it")
        reply.metadata[TurnKey.ambiguous] = nil
        #expect(store.reassignWorkflowTask(workflow.id, taskID: "task", botID: b.id))
        let task = try #require(store.workflows[workflow.id]?.tasks.first)
        #expect(task.botID == b.id && task.state == .queued && task.threadID != thread.id && task.previousThreadIDs == ([thread.id] as [UUID]))
        #expect(!store.send(text: "Retry old work", bot: a, conversation: thread, replyToID: nil) && store.errorMessage?.contains("reassigned") == true)
        #expect(try store.journal().records(Workflow.self, kind: AppStore.workflowKind).first?.tasks.first?.previousThreadIDs == ([thread.id] as [UUID]))
    }

    @Test func plansAndBudgetsAreValidated() throws {
        let botID = UUID()
        let task = WorkflowTask(id: "a", botID: botID, instructions: "Do work", expectedOutput: "Result", dependencies: ["b"])
        let cycle = WorkflowTask(id: "b", botID: botID, instructions: "Do work", expectedOutput: "Result", dependencies: ["a"])
        #expect(throws: (any Error).self) { try Workflow.validate([task, cycle], members: [botID]) }
        #expect(throws: (any Error).self) { try Workflow.validate([task], members: []) }
        #expect(throws: (any Error).self) { try Workflow.validate([], members: [botID]) }
        let many = (0..<12).map { WorkflowTask(id: "t\($0)", botID: botID, instructions: "x", expectedOutput: "y", dependencies: []) }
        #expect(throws: (any Error).self) { try WorkflowProposal(tasks: many.map { .init(id: $0.id, botID: botID, instructions: "x", expectedOutput: "y") }).validated(members: [botID]) }
        var budget = RunBudget(id: UUID(), tokenLimit: 100)
        try budget.reserve(90)
        #expect(throws: (any Error).self) { try budget.reserve(11) }
        budget.settle(reservation: 90, actual: 95)
        #expect(budget.reserved == 0 && budget.spent == 95)
    }
}

@MainActor @Test func p38dShotsRenderFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppP38D-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "p38d", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessP38DShots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38DShots.names.count, "only the P38 D shots")
}

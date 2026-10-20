import Foundation
import Testing
import SwarmHubCoordination
@testable import AgentApp

@MainActor struct ReviewAcceptanceConfigTests {
    @Test func narrowedReviewPromptAndCompletionRequireUserAcceptance() throws {
        let (store, original, _, _, owner, _) = try WorkflowOperationsTests().fixture()
        var workflow = original; workflow.state = .paused
        workflow.tasks[0].reviewTargetID = "source"; workflow.tasks[0].reviewRound = 1
        try store.saveWorkflow(workflow)
        store.appConfig = AppConfigWiringTests.bundled
        store.authorizeTeamWorkflow(workflow.id)
        workflow = try #require(store.workflows[workflow.id]); workflow.state = .running
        try store.saveWorkflow(workflow)
        let tools = try #require(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: owner))
        let prompt = try tools.instructions("[[MARKER]]")
        #expect(prompt.contains("The result goes to the user for acceptance"))
        #expect(!prompt.contains("include your verdict") && !prompt.contains("reportResult"))
        let reply = ChatMessage(role: .assistant, content: #"accepted; {"verdict":"accepted"}"#, turnState: .finished)
        store.applyWorkflowCompletion(&workflow, index: 0, reply: reply)
        try store.saveWorkflow(workflow)
        #expect(workflow.tasks[0].result == reply.content && workflow.tasks[0].reviewVerdict == nil)
        #expect(workflow.tasks[0].state == .awaitingUserAcceptance && workflow.tasks[0].reviewBlock == nil)
        #expect(workflow.tasks[0].error == nil && workflow.error == nil)
        #expect(workflow.stateLabel == "Waiting for user acceptance")
        #expect(workflow.tasks[0].stateLabel == "Waiting for user acceptance")
        #expect(store.canAcceptWorkflowReview(workflow, task: workflow.tasks[0]))
        #expect(!store.canReassignWorkflowTask(workflow, task: workflow.tasks[0]))
        store.confirmTeamEvidence(workflow.id, taskID: "work")
        store.resumeWorkflow(workflow.id)
        #expect(store.workflows[workflow.id]?.tasks[0].state == .awaitingUserAcceptance)
        #expect(store.workflows[workflow.id]?.state == .paused && store.errorMessage == nil)
        let saved = try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(workflow))
        store.restoreTeamWorkflow(saved)
        #expect(store.workflows[workflow.id]?.tasks[0].state == .awaitingUserAcceptance)
        #expect(store.workflows[workflow.id]?.error == nil)
        store.acceptWorkflowReview(workflow.id, taskID: "work")
        #expect(store.workflows[workflow.id]?.tasks[0].state == .completed)
        #expect(store.workflows[workflow.id]?.tasks[0].reviewAcceptedByUser == true)
        #expect(store.workflows[workflow.id]?.state == .paused)
    }

    @Test(arguments: [false, true])
    func permittedReportingKeepsItsCompletionBehavior(structured: Bool) throws {
        let (store, original, _, tools, _, _) = try WorkflowOperationsTests().fixture()
        var workflow = original
        workflow.tasks[0].reviewTargetID = "source"
        try store.saveWorkflow(workflow)
        #expect(try tools.instructions("[[MARKER]]").contains("reportResult with a verdict is required"))
        if structured { workflow.tasks[0].reviewVerdict = .accepted }
        store.applyWorkflowCompletion(&workflow, index: 0,
            reply: ChatMessage(role: .assistant, content: "accepted", turnState: .finished))
        #expect(workflow.tasks[0].state == (structured ? .completed : .blocked))
        #expect(workflow.state == (structured ? .running : .paused))
        #expect((workflow.tasks[0].reviewBlock != nil) == !structured)
        #expect((workflow.error != nil) == !structured)
    }

    @Test func reviewCompletionPreservesParallelRecoveryIntentButStillBlocksResume() async throws {
        let backend = ScriptedTurnBackend()
        let (store, author, peer) = TeamRecoveryTests().fixture(backend)
        store.turns.pathDown = true
        #expect(store.startTeamRequest("Review TEST work", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        var workflow = try #require(store.workflows.values.first)
        workflow.coordination?.policy.actions = ["assign", "requestReview"]
        workflow.coordination?.limits.parallelTasks = 2
        workflow.tasks[0].reviewTargetID = "source"; workflow.tasks[0].state = .running
        workflow.tasks[1].dependencies = []; workflow.tasks[1].state = .running
        workflow.state = .running
        let sibling = ChatThread(id: workflow.tasks[1].threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil)
        let unfinished = ChatMessage(role: .assistant, content: "", turnState: .incomplete)
        sibling.messages = [unfinished]; author.threads.append(sibling)
        workflow.tasks[1].replyID = unfinished.id
        try store.saveWorkflow(workflow)
        store.settleWorkflows() // The parallel sibling blocks first and owns the recovery intent.
        workflow = try #require(store.workflows[workflow.id])
        #expect(workflow.tasks[1].state == .blocked && workflow.coordination?.resumeAfterRecovery == true)
        store.applyWorkflowCompletion(&workflow, index: 0,
            reply: ChatMessage(role: .assistant, content: "Review findings", turnState: .finished))
        #expect(workflow.coordination?.resumeAfterRecovery == true)
        try store.saveWorkflow(workflow)
        store.turns.pathDown = false
        await store.recoverTeams()
        #expect(store.workflows[workflow.id]?.state == .paused)
        unfinished.content = "Recovered sibling result"; unfinished.turnState = .finished
        store.settleWorkflows()
        await store.recoverTeams(); store.reconcileTeamOutcome(sibling); store.resumeWorkflow(workflow.id)
        let waiting = try #require(store.workflows[workflow.id])
        #expect(waiting.tasks[1].state == .completed && waiting.awaitsUserAcceptance)
        #expect(waiting.coordination?.resumeAfterRecovery == true && waiting.state == .paused)
        #expect(backend.calls.all.isEmpty)
    }

    @Test(arguments: [false, true], [["assign", "requestReview"], ["assign", "reportResult", "requestReview"]])
    func acceptedReviewRequiresResumeAfterSiblingRecovery(recoveryFirst: Bool, actions: [String]) async throws {
        let backend = ScriptedTurnBackend()
        let (store, author, peer) = TeamRecoveryTests().fixture(backend)
        store.turns.pathDown = true
        #expect(store.startTeamRequest("Review TEST work", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        var workflow = try #require(store.workflows.values.first)
        workflow.coordination?.policy.actions = Set(actions)
        workflow.coordination?.limits.parallelTasks = 2
        workflow.tasks[0].reviewTargetID = "source"; workflow.tasks[0].state = .running
        workflow.tasks[1].id = "sibling"; workflow.tasks[1].dependencies = []; workflow.tasks[1].state = .running
        workflow.tasks.append(.init(id: "final", botID: author.id, instructions: "Summarize", expectedOutput: "Answer",
                                    dependencies: [workflow.tasks[0].id, "sibling"]))
        let sibling = ChatThread(id: workflow.tasks[1].threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil)
        let reply = ChatMessage(role: .assistant, content: "", turnState: .incomplete)
        sibling.messages = [reply]; author.threads.append(sibling)
        workflow.tasks[1].replyID = reply.id
        try store.saveWorkflow(workflow)
        store.settleWorkflows()
        workflow = try #require(store.workflows[workflow.id])
        #expect(workflow.tasks[1].state == .blocked && workflow.coordination?.resumeAfterRecovery == true)
        store.applyWorkflowCompletion(&workflow, index: 0,
            reply: ChatMessage(role: .assistant, content: "Review findings", turnState: .finished))
        try store.saveWorkflow(workflow)
        store.turns.pathDown = false
        if recoveryFirst {
            reply.content = "Recovered sibling result"; reply.turnState = .finished
            await store.recoverTeams()
        }
        store.acceptWorkflowReview(workflow.id, taskID: workflow.tasks[0].id)
        let accepted = try #require(store.workflows[workflow.id])
        #expect(accepted.state == .paused && accepted.coordination?.resumeAfterRecovery == false)
        #expect(accepted.tasks[0].state == .completed && accepted.tasks[0].reviewAcceptedByUser == true)
        let saved = try #require(try store.journal().records(Workflow.self, kind: AppStore.workflowKind).first)
        #expect(saved.coordination?.resumeAfterRecovery == false)
        reply.content = "Recovered sibling result"; reply.turnState = .finished
        await store.recoverTeams(); store.reconcileTeamOutcome(sibling); store.dispatchWorkflows()
        let recovered = try #require(store.workflows[workflow.id])
        #expect(recovered.tasks[1].state == .completed && recovered.tasks[2].state == .queued)
        #expect(recovered.state == .paused && backend.calls.all.isEmpty)
        store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 1 }
        await backend.emit(.token("Consolidated findings"), .completed); await backend.end()
        try await waitUntil { store.workflows[workflow.id]?.state == .completed }
    }

    @Test(arguments: [["assign", "requestReview"], ["assign"]])
    func reviewsWaitForAcceptanceBeforeSynthesis(actions: [String]) async throws {
        let backend = ScriptedTurnBackend()
        let (store, author, reviewer) = TeamRecoveryTests().fixture(backend)
        store.appConfig = AppConfigWiringTests.bundled
        store.appConfig.teamActions = actions
        let group = GroupChat(name: "Team", memberIDs: [author.id, reviewer.id]); store.groups = [group]
        var review = WorkflowTask(id: "review", botID: reviewer.id, instructions: "Review fixture", expectedOutput: "Findings", dependencies: [])
        review.reviewTargetID = "source"
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: author.id, request: "Review", state: .paused,
            tasks: [review, .init(id: "final", botID: author.id, instructions: "Summarize", expectedOutput: "Answer", dependencies: [review.id])],
            budget: .init(id: UUID(), tokenLimit: 64_000))
        try store.saveWorkflow(workflow); store.authorizeTeamWorkflow(workflow.id); store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 1 }
        let sent = try #require(store.workflows[workflow.id]?.tasks[0].delivery?.envelope.payload)
        #expect(sent.contains("The result goes to the user for acceptance"))
        await backend.emit(.token("accepted"), .completed); await backend.end()
        try await waitUntil { !store.anyTurnRunning }
        let waiting = try #require(store.workflows[workflow.id])
        #expect(waiting.tasks[0].state == .awaitingUserAcceptance && waiting.error == nil)
        #expect(waiting.tasks[1].state == .queued)
        // Even a saved recovery intent cannot release dependent work before the user's decision.
        store.workflows[workflow.id]?.coordination?.resumeAfterRecovery = true
        await store.recoverTeams(); store.resumeWorkflow(workflow.id)
        #expect(backend.calls.all.filter { $0.hasPrefix("send:") }.count == 1)
        store.acceptWorkflowReview(workflow.id, taskID: review.id); store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 2 }
        await backend.emit(.token("Consolidated findings"), .completed); await backend.end()
        try await waitUntil { store.workflows[workflow.id]?.state == .completed }
    }
}

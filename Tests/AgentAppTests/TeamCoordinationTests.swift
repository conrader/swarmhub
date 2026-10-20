import Foundation
import Testing
import SwarmHubCoordination
@testable import AgentApp

@MainActor struct TeamCoordinationTests {
    @Test func authorizedHelpReviewRevisionAndSynthesisNeedOneDecision() async throws {
        let (store, backend, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        store.resumeWorkflow(id)
        try await waitUntil { store.workflows[id]?.isFinished == true || store.workflows[id]?.state == .paused }
        let workflow = try #require(store.workflows[id])
        #expect(workflow.state == .completed, "\(workflow.error ?? "")")
        #expect(workflow.tasks.count == 7 && workflow.tasks.allSatisfy { $0.delivery?.state == .completed })
        #expect(workflow.tasks.filter { $0.reviewTargetID != nil }.map(\.reviewRound) == ([1, 2] as [Int?]))
        #expect(await backend.recordedPrompts().count == 7)
        #expect(store.groups[0].messages.count == 1)
        store.projectWorkflowResult(workflow); store.dispatchWorkflows()
        #expect(store.groups[0].messages.count == 1)
        #expect(await backend.recordedPrompts().count == 7)
        #expect(workflow.tasks.allSatisfy { $0.verifiedByUser != true }, "A reviewer verdict or prose must not claim human verification.")
    }

    @Test func offlineWorkWaitsAndRevocationPreventsDispatch() async throws {
        let backend = ScriptedTurnBackend(); let (store, sender) = steerStore(backend)
        let peer = Bot(name: "Peer", backend: .hermes, hermesProfile: "peer"); store.bots.append(peer)
        store.turns.pathDown = true
        #expect(store.startTeamRequest("Inspect", origin: sender, coordinator: sender, recipient: peer, roster: [sender, peer]))
        let id = try #require(store.workflows.keys.first)
        #expect(store.workflows[id]?.tasks.allSatisfy { $0.state == .queued } == true && backend.calls.all.isEmpty)
        store.revokeTeamPolicy(id); store.turns.pathDown = false; store.resumeWorkflow(id)
        #expect(store.workflows[id]?.state == .paused && backend.calls.all.isEmpty)
    }

    @Test func aChangedConnectionDoesNotInheritTheOldPermission() throws {
        let (store, _, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        store.bots[1].hermesProfile = "another-profile"
        let workflow = try #require(store.workflows[id])
        #expect(store.workflowMembers(workflow).count == 1)
        #expect(store.teamPolicyProblem(workflow, botID: store.bots[1].id) != nil)
    }

    @Test func anotherDeviceCannotTakeOverByReauthorizing() throws {
        let (store, _, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        var copied = try #require(store.workflows[id]); copied.coordination?.policy.ownerDeviceID = "other-device"
        store.workflows[id] = copied
        store.authorizeTeamWorkflow(id)
        #expect(store.workflows[id]?.coordination?.policy.ownerDeviceID == "other-device")
        #expect(store.teamPolicyProblem(copied) != nil)
    }

    @Test func oneLocalProcessOwnsTheDispatcher() {
        let path = temporaryStore().deletingLastPathComponent().appending(path: "lease")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = TeamDispatchLease(), second = TeamDispatchLease()
        #expect(first.acquire(at: path))
        #expect(!second.acquire(at: path))
    }

    @Test func missingLocalThreadIsRebuiltFromCommittedIntentWithoutResend() throws {
        let (store, _, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        var workflow = try #require(store.workflows[id])
        let task = workflow.tasks[0], identity = store.teamIdentity(store.bots[0])
        let envelope = TeamEnvelope(operationID: "send", taskID: task.id, conversationID: workflow.groupID,
            recipient: identity, replyToID: nil, kind: "task", payload: "Inspect synthetic input")
        var delivery = try TeamDelivery(envelope: envelope, sessionID: store.workflowSessionID(task.threadID), replyID: UUID(), at: store.now())
        delivery.record(.dispatching, at: store.now())
        workflow.state = .running; workflow.tasks[0].state = .running
        workflow.tasks[0].delivery = delivery; workflow.tasks[0].replyID = delivery.replyID
        try store.saveWorkflow(workflow)
        store.restoreWorkflows()
        let restored = try #require(store.workflows[id])
        let thread = try #require(store.workflowThread(task.threadID, botID: task.botID))
        #expect(restored.state == .paused && restored.tasks[0].delivery?.state == .uncertain)
        #expect(thread.hermesSessionID == delivery.sessionID && thread.messages.last?.id == delivery.replyID)
        #expect(!store.canReassignWorkflowTask(restored, task: restored.tasks[0]))
        store.dispatchWorkflows()
        #expect(!store.anyTurnRunning)
    }

    @Test func projectFactsRespectReadersAndConnectionChanges() {
        let (store, sender) = steerStore(ScriptedTurnBackend())
        let peer = Bot(name: "Peer", backend: .hermes, hermesProfile: "peer"); store.bots.append(peer)
        let fact = ProjectFact(projectID: sender.id, text: "Forecast assumes 12 months", source: "user decision", owner: "User", at: .now,
                               kind: .userDecision, readers: [store.teamIdentity(sender)])
        #expect(store.saveProjectFact(fact))
        #expect(store.projectContext(projectID: sender.id, for: sender).contains("12 months"))
        #expect(store.projectContext(projectID: sender.id, for: peer).isEmpty)
        sender.hermesProfile = "replacement"
        #expect(store.projectContext(projectID: sender.id, for: sender).isEmpty)
    }

    @Test func remoteCompletionDoesNotVerifyRequiredChecks() throws {
        let (store, _, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        var workflow = try #require(store.workflows[id]); workflow.coordination?.requiresEvidence = true
        workflow.tasks[0].state = .completed; workflow.tasks[0].completionConfirmed = true
        store.settleTeamDelivery(&workflow, index: 0, reply: ChatMessage(role: .assistant, content: "Deployed", turnState: .finished))
        #expect(workflow.tasks[0].state == .blocked && workflow.state == .paused)
        try store.saveWorkflow(workflow); store.confirmTeamEvidence(id, taskID: workflow.tasks[0].id)
        #expect(store.workflows[id]?.tasks[0].verifiedByUser == true)
    }

    @Test func quietHoursUseLocalCivilTimeAcrossDST() throws {
        var reporting = TeamReporting(); reporting.timeZoneID = "Europe/Warsaw"; reporting.quietStartMinute = 22 * 60; reporting.quietEndMinute = 8 * 60
        let parser = ISO8601DateFormatter()
        let beforeFallback = try #require(parser.date(from: "2026-10-25T00:30:00Z"))
        #expect(reporting.isQuiet(at: beforeFallback))
        let afterFallback = try #require(parser.date(from: "2026-10-25T01:30:00Z"))
        #expect(reporting.isQuiet(at: afterFallback))
        let morning = try #require(parser.date(from: "2026-10-25T07:00:00Z"))
        #expect(!reporting.isQuiet(at: morning))
    }

    @Test func speechUsesOnlyTheFinishedRealReply() {
        let reply = ChatMessage(role: .assistant, content: "Real answer", isStreaming: true, turnState: .incomplete)
        #expect(ReplySpeech.text(for: reply) == nil)
        reply.isStreaming = false; reply.turnState = .finished
        #expect(ReplySpeech.text(for: reply) == "Real answer")
    }
}

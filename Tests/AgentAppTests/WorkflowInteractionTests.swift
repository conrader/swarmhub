import AppKit
import Foundation
import Testing
@testable import AgentApp

// P38 E: agents inside a workflow ask for help and review through the hidden operation envelope; the user approves each
// expanded plan; a second rejection waits for "Accept review with noted limitations". Scripted backend, no network.

actor WorkflowScriptBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    let helperID: UUID
    let rejectSecondReview: Bool
    var calls: [String: Int] = [:]
    var prompts: [String] = []
    init(helperID: UUID, rejectSecondReview: Bool = false) { self.helperID = helperID; self.rejectSecondReview = rejectSecondReview }
    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { id ?? UUID().uuidString }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let step = calls[request.sessionID, default: 0]; calls[request.sessionID] = step + 1
        let input = request.messages.first(where: { $0.role == "user" })?.content ?? ""
        if step == 0 { prompts.append(input) }
        let lines = request.systemPrompt.components(separatedBy: "\n")
        let marker = try #require(lines.first { $0.hasPrefix("[[SWARMHUB_APP_REQUEST_") })
        let taskLine = try #require(lines.first { $0.contains(" workflow operations for your task ") })
        let taskID = String(try #require(taskLine.components(separatedBy: " workflow operations for your task ").last).dropLast())
        let hasHandoff = input.hasPrefix("Task: Research fixture") || input.hasPrefix("Task: Continue the original task")
        let output: String
        if hasHandoff && step == 0 {
            let help = input.hasPrefix("Task: Research fixture")
            output = try envelope(.init(operationID: taskID + "-handoff", action: help ? .requestHelp : .requestReview, botID: helperID,
                                        instructions: help ? "Find supporting evidence" : "Check the claims", expectedOutput: help ? "Sources" : "Verdict and findings"), marker: marker)
        } else if step == (hasHandoff ? 1 : 0) {
            let reviewing = input.hasPrefix("Task: Check the claims")
            let second = request.systemPrompt.contains("in round 2;")
            let result = input.hasPrefix("Task: Summarize fixture") ? "Consolidated verified answer" : (reviewing ? "Review findings" : "Supporting evidence")
            output = try envelope(.init(operationID: taskID + "-result", action: .reportResult, result: result,
                                        verdict: reviewing ? (second && !rejectSecondReview ? .accepted : .needsRevision) : nil), marker: marker)
        } else { output = "Finished this task." }
        return AsyncThrowingStream { continuation in
            for part in [String(output.prefix(8)), String(output.dropFirst(8))] { continuation.yield(.token(part)) }
            continuation.yield(.completed); continuation.finish()
        }
    }
    private func envelope(_ operation: WorkflowOperation, marker: String) throws -> String {
        let value = try JSONDecoder().decode(ComposioValue.self, from: JSONEncoder().encode(operation))
        return marker + "\n" + (try ComposioValue.object(["action": .string("workflow"), "arguments": value]).text())
    }
    func recordedPrompts() -> [String] { prompts }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "synthetic workflow" }
}

/// Reports a result, then the next step's stream drops before a terminal event.
actor ReportThenDisconnectBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    var count = 0
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        count += 1; let first = count == 1
        let marker = try #require(request.systemPrompt.components(separatedBy: "\n").first { $0.hasPrefix("[[SWARMHUB_APP_REQUEST_") })
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.token(marker + #"{"action":"workflow","arguments":{"operationID":"report","action":"reportResult","result":"Evidence"}}"#))
                continuation.yield(.completed)
            } else { continuation.yield(.token("Partial reply")) }
            continuation.finish()
        }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "synthetic" }
}

@MainActor struct WorkflowInteractionTests {
    func fixture(rejectSecondReview: Bool = false) throws -> (AppStore, WorkflowScriptBackend, UUID) {
        let author = Bot(name: "Author", backend: .hermes), helper = Bot(name: "Helper", backend: .hermes)
        let backend = WorkflowScriptBackend(helperID: helper.id, rejectSecondReview: rejectSecondReview)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = [author, helper]
        let group = GroupChat(name: "Team", memberIDs: [author.id, helper.id]); store.groups = [group]
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: author.id, request: "Research", state: .paused,
            tasks: [.init(id: "research", botID: author.id, instructions: "Research fixture", expectedOutput: "Evidence", dependencies: []),
                    .init(id: "final", botID: author.id, instructions: "Summarize fixture", expectedOutput: "Answer", dependencies: ["research"])],
            budget: .init(id: UUID(), tokenLimit: 200_000))
        try store.saveWorkflow(workflow)
        return (store, backend, workflow.id)
    }

    func resumeAndSettle(_ store: AppStore, _ id: UUID) async throws {
        store.resumeWorkflow(id)
        try await waitUntil { !store.anyTurnRunning && store.workflows[id]?.state != .running && store.workflows[id]?.tasks.contains { $0.state == .running } == false }
    }

    @Test func helpReviewRevisionAndSynthesisRunWithoutConnectedAppCredentials() async throws {
        let (store, backend, id) = try fixture()
        #expect(store.connectedApps.grants(for: store.bots[0].id).isEmpty)
        for _ in 0..<4 {
            try await resumeAndSettle(store, id)
            #expect(store.workflows[id]?.tasks.contains { $0.state == .blocked } == false)
        }
        let workflow = try #require(store.workflows[id])
        #expect(workflow.state == .completed && workflow.tasks.count == 7)
        #expect(workflow.tasks.allSatisfy { $0.state == .completed && $0.resultArtifactID != nil })
        #expect(workflow.operations?.count == 9)
        #expect(workflow.tasks.filter { $0.reviewTargetID != nil }.map(\.reviewRound) == [1, 2])
        #expect(store.groups[0].messages.map(\.content) == ["Consolidated verified answer"])
        #expect(workflow.budget.reserved == 0 && workflow.budget.spent > 0)
        let prompts = await backend.recordedPrompts()
        #expect(prompts.count == 7)
        #expect(prompts.first { $0.hasPrefix("Task: Revise") }?.contains("Review findings") == true)
        #expect(prompts.first { $0.hasPrefix("Task: Revise") }?.contains("needsRevision") == true)
        #expect(store.bots.flatMap(\.threads).flatMap(\.messages).allSatisfy { !$0.content.contains("SWARMHUB_APP_REQUEST") })
    }

    @Test func aSecondRejectionHoldsTheSynthesisUntilTheUserAcceptsTheReview() async throws {
        let (store, backend, id) = try fixture(rejectSecondReview: true)
        for _ in 0..<4 { try await resumeAndSettle(store, id) }
        let workflow = try #require(store.workflows[id])
        let blocked = try #require(workflow.tasks.first { $0.state == .blocked })
        #expect(blocked.reviewRound == 2 && blocked.reviewVerdict == .needsRevision && blocked.result == "Review findings")
        #expect(workflow.tasks.count == 7 && workflow.tasks.last?.state == .queued)
        #expect(await backend.recordedPrompts().count == 6)
        store.resumeWorkflow(id)
        #expect(store.workflows[id]?.state == .paused)
        store.acceptWorkflowReview(id, taskID: blocked.id); store.resumeWorkflow(id)
        try await waitUntil { store.workflows[id]?.state == .completed }
        #expect(store.workflows[id]?.tasks.first { $0.id == blocked.id }?.reviewAcceptedByUser == true)
        #expect(store.groups[0].messages.count == 1)
        let synthesis = try #require(await backend.recordedPrompts().last)
        #expect(synthesis.contains("The user accepted its noted limitations: yes"))
    }

    @Test func hiddenOperationTurnsAreChargedToTheAllowance() async throws {
        let (store, _, id) = try fixture()
        store.resumeWorkflow(id)
        try await waitUntil { !store.anyTurnRunning && store.workflows[id]?.state == .paused && store.workflows[id]?.tasks.first?.state == .completed }
        let workflow = try #require(store.workflows[id])
        let reply = try #require(store.bots[0].threads.first { $0.id == workflow.tasks[0].threadID }?.messages.last { $0.role == .assistant })
        let hidden = try #require(Int(reply.metadata[TurnKey.toolTokens] ?? ""))
        let visible = (Int(reply.metadata["estimatedInputTokens"] ?? "") ?? 0) + reply.content.utf8.count / 4
        #expect(hidden > 0 && reply.content == "Finished this task.")
        #expect(workflow.budget.spent == visible + hidden)
    }

    @Test func workflowToolAccessDoesNotGrantAppAccess() async throws {
        let (apps, host, _) = composioFixture()
        let workflow = WorkflowTools(instructions: { marker in "Workflow enabled\n" + marker }, validate: {}, perform: { _ in "ok" })
        let stream = try await ConnectedAppsChat.stream(.init(sessionID: "test", systemPrompt: "", messages: []), botID: UUID(),
                                                        backend: AppRequestBackend(), apps: apps, workflow: workflow)
        do {
            for try await _ in stream {}
            Issue.record("An ungranted app request unexpectedly succeeded")
        } catch { #expect(error.localizedDescription.contains("no connected app grants")) }
        #expect(MockHermesProtocol.recorded(host).isEmpty)
    }

    @Test func aBotOutsideTheAppGateGetsNoAppToolsEvenWithAGrant() async throws {
        let (apps, host, _) = composioFixture()
        let botID = UUID()
        await apps.refresh(); apps.setAllowed(true, account: apps.accounts[0], botID: botID)
        #expect(!apps.grants(for: botID).isEmpty)
        let before = MockHermesProtocol.recorded(host).count
        let workflow = WorkflowTools(instructions: { marker in "Workflow enabled\n" + marker }, validate: {}, perform: { _ in "ok" })
        let stream = try await ConnectedAppsChat.stream(.init(sessionID: "test", systemPrompt: "", messages: []), botID: botID,
                                                        backend: AppRequestBackend(), apps: apps, appsAllowed: false, workflow: workflow)
        do {
            for try await _ in stream {}
            Issue.record("A bot outside the app gate reached app tools")
        } catch { #expect(error.localizedDescription.contains("no connected app grants")) }
        #expect(MockHermesProtocol.recorded(host).count == before)
    }

    @Test func aReportFollowedByAConnectionLossNeverCompletesTheTask() async throws {
        let (store, workflow, _, tools, owner, _) = try WorkflowOperationsTests().fixture()
        let stream = try await ConnectedAppsChat.stream(.init(sessionID: "work-session", systemPrompt: "", messages: []), botID: owner.id,
                                                        backend: ReportThenDisconnectBackend(), apps: store.connectedApps, workflow: tools)
        do {
            for try await _ in stream {}
            Issue.record("A missing terminal event unexpectedly completed the turn")
        } catch { #expect(error.localizedDescription.contains("before completion")) }
        #expect(store.workflows[workflow.id]?.tasks[0].reportedResult == "Evidence")
        #expect(store.workflows[workflow.id]?.tasks[0].state == .running)
        #expect(store.workflows[workflow.id]?.tasks[0].completionConfirmed != true)
    }

    @Test func aCommittedRevisionSurvivesACrashAndRefreshDoesNotCreateItAgain() async throws {
        let url = temporaryStore()
        let backend = TestBackend(transport: .nativeSessions)
        let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let author = Bot(name: "Author", backend: .hermes), reviewer = Bot(name: "Reviewer", backend: .hermes); store.bots = [author, reviewer]
        let group = GroupChat(name: "Team", memberIDs: [author.id, reviewer.id]); store.groups = [group]
        let original = WorkflowTask(id: "original", botID: author.id, instructions: "Research", expectedOutput: "Evidence", dependencies: [], state: .completed, result: "Initial evidence")
        var review = WorkflowTask(id: "review", botID: reviewer.id, instructions: "Review", expectedOutput: "Verdict", dependencies: [original.id], state: .running)
        review.reviewTargetID = original.id; review.reviewRootID = original.id; review.reviewRound = 1
        let final = WorkflowTask(id: "final", botID: author.id, instructions: "Summarize", expectedOutput: "Answer", dependencies: [review.id])
        var workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: author.id, request: "Research", state: .running,
                                tasks: [original, review, final], budget: .init(id: UUID(), tokenLimit: 100_000))
        let user = ChatMessage(role: .user, content: "Review the findings")
        let reply = ChatMessage(role: .assistant, content: "Review", turnState: .incomplete)
        workflow.tasks[1].replyID = reply.id
        reviewer.threads = [ChatThread(id: review.threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil, messages: [user, reply])]
        let receipt = try workflow.apply(.init(operationID: "review-result", action: .reportResult, result: "The source needs correction", verdict: .needsRevision),
                                         taskID: review.id, members: Set(group.memberIDs))
        #expect(receipt.createdTaskIDs.count == 2)
        try store.saveWorkflow(workflow); store.save()
        let restored = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(restored.workflows[workflow.id]?.tasks[1].state == .blocked)
        restored.resumeWorkflow(workflow.id)
        #expect(restored.workflows[workflow.id]?.state == .paused)
        // The reconcile (or Retry) found the reply finished.
        restored.bots[1].threads[0].messages.last?.turnState = .finished
        await restored.refreshWorkflowTask(workflow.id, taskID: review.id)
        await restored.refreshWorkflowTask(workflow.id, taskID: review.id)
        let recovered = try #require(restored.workflows[workflow.id])
        #expect(recovered.tasks.count == 5 && recovered.operations?.count == 1)
        #expect(recovered.tasks[1].state == .completed && recovered.tasks[1].reviewVerdict == .needsRevision)
        #expect(recovered.tasks[1].result == "The source needs correction")
        #expect(recovered.tasks.filter { receipt.createdTaskIDs.contains($0.id) }.allSatisfy { $0.state == .queued })
        #expect(recovered.state == .paused)
        #expect(!backend.calls.all.contains("send"))
    }
}

@MainActor @Test func p38eShotsRenderFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppP38E-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "p38e", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessP38EShots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38EShots.names.count, "only the P38 E shots")
}

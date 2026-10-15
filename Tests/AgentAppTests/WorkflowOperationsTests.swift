import Foundation
import Testing
@testable import AgentApp

// P38 E: workflow operations (assign, help, review, report) on main's one-turn engine. No network: the tools are bound
// to a synthetic streaming turn.

@MainActor struct WorkflowOperationsTests {
    func fixture(coordinator: Bool = true) throws -> (AppStore, Workflow, ChatThread, WorkflowTools, Bot, Bot) {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let owner = Bot(name: "Owner", backend: .mock), other = Bot(name: "Other", backend: .mock)
        store.bots = [owner, other]
        let group = GroupChat(name: "Team", memberIDs: [owner.id, other.id]); store.groups = [group]
        let task = WorkflowTask(id: "work", botID: owner.id, instructions: "Research", expectedOutput: "Evidence", dependencies: [], state: .running)
        let final = WorkflowTask(id: "final", botID: owner.id, instructions: "Summarize", expectedOutput: "Answer", dependencies: [task.id])
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: coordinator ? owner.id : other.id, request: "Research",
                                state: .running, tasks: [task, final], budget: .init(id: UUID(), tokenLimit: 100_000))
        try store.saveWorkflow(workflow)
        let thread = ChatThread(id: task.threadID, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: "work-session")
        owner.threads = [thread]
        // The turn now streaming in the task's thread.
        store.streamingConversation = thread; store.streamingBotID = owner.id; store.activeStreamToken = UUID()
        let tools = try #require(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: owner))
        return (store, workflow, thread, tools, owner, other)
    }

    func arguments(_ operation: WorkflowOperation) throws -> ComposioValue {
        try JSONDecoder().decode(ComposioValue.self, from: JSONEncoder().encode(operation))
    }

    @Test func onlyTheStreamingTaskTurnGetsTools() throws {
        let (store, _, thread, tools, owner, other) = try fixture()
        #expect(try tools.instructions("[[MARKER]]").contains("your task work"))
        #expect(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: other) == nil)
        #expect(try store.workflowTools(for: .init(sessionID: "elsewhere", systemPrompt: "", messages: []), bot: owner) == nil)
        store.streamingConversation = owner
        #expect(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: owner) == nil)
        store.streamingConversation = thread
    }

    @Test func duplicateHandoffIsDurableAndChangedPayloadIsRejected() throws {
        let (store, workflow, _, tools, _, other) = try fixture()
        let op = WorkflowOperation(operationID: "work-help", action: .requestHelp, botID: other.id, instructions: "Find sources", expectedOutput: "Sources")
        let first = try tools.perform(arguments(op)); let second = try tools.perform(arguments(op))
        #expect(first == second)
        let saved = try #require(store.workflows[workflow.id])
        #expect(saved.tasks.count == 4 && saved.state == .paused && saved.operations?.count == 1)
        let continuation = try #require(saved.tasks.first { $0.id.hasPrefix("continue-") })
        #expect(saved.tasks.last?.dependencies == [continuation.id])
        #expect(continuation.dependencies.contains("work"))
        var persisted = try #require(try store.journal().records(Workflow.self, kind: AppStore.workflowKind).first)
        #expect(try persisted.apply(op, taskID: "work", members: Set(store.bots.map(\.id))).toolResult() == first)
        var changed = op; changed.instructions = "Find  sources"
        #expect(throws: (any Error).self) { try tools.perform(arguments(changed)) }
        #expect(store.workflows[workflow.id]?.tasks.count == 4)
    }

    @Test func schemaRejectsSpoofedIdentityWrongFieldsAndOversizedReports() throws {
        let spoofed: ComposioValue = .object(["operationID": .string("x"), "action": .string("reportResult"), "result": .string("ok"), "taskID": .string("foreign")])
        #expect(throws: (any Error).self) { try WorkflowOperation.parse(spoofed) }
        let wrong: ComposioValue = .object(["operationID": .string("x"), "action": .string("reportResult"), "result": .string("ok"), "botID": .null])
        #expect(throws: (any Error).self) { try WorkflowOperation.parse(wrong) }
        #expect(throws: (any Error).self) { try WorkflowOperation(operationID: "x", action: .reportResult, result: String(repeating: "🙂", count: 6_001)).validate() }
        #expect(throws: (any Error).self) { try WorkflowOperation(operationID: "bad id", action: .reportResult, result: "ok").validate() }
        #expect(throws: (any Error).self) { try WorkflowOperation(operationID: "x", action: .requestHelp, botID: UUID(), instructions: "a", expectedOutput: "b", role: .reviewer).validate() }
        let marker = "[[SWARMHUB_APP_REQUEST_\(UUID().uuidString)]]"
        #expect(throws: (any Error).self) { try AppToolRequest.parse(marker + #"{"action":"workflow","query":"other","arguments":{}}"#, marker: marker) }
        #expect(try AppToolRequest.parse(marker + #"{"action":"workflow","arguments":{"operationID":"a"}}"#, marker: marker)?.action == .workflow)
    }

    @Test func authorizationChecksTheCurrentTurnMembershipAndSession() throws {
        let (store, workflow, thread, tools, owner, other) = try fixture(coordinator: false)
        let assign = WorkflowOperation(operationID: "assign", action: .assign, botID: other.id, instructions: "Do work", expectedOutput: "Result")
        #expect(throws: (any Error).self) { try tools.perform(arguments(assign)) }
        let report = try arguments(.init(operationID: "result", action: .reportResult, result: "Evidence"))
        store.groups[0].memberIDs.removeAll { $0 == owner.id }
        #expect(throws: (any Error).self) { try tools.perform(report) }
        store.groups[0].memberIDs.append(owner.id)
        thread.hermesSessionID = "changed"
        #expect(throws: (any Error).self) { try tools.perform(report) }
        thread.hermesSessionID = "work-session"
        store.workflows[workflow.id]?.state = .cancelled
        #expect(throws: (any Error).self) { try tools.perform(report) }
        store.workflows[workflow.id]?.state = .running
        store.activeStreamToken = UUID()
        #expect(throws: (any Error).self) { try tools.perform(report) }
        #expect(store.workflows[workflow.id]?.operations == nil)
    }

    @Test func journalFailureLeavesNoVisibleHandoffOrReceipt() throws {
        let (store, workflow, _, tools, _, other) = try fixture()
        store.runtime = RejectingRuntime()
        let op = WorkflowOperation(operationID: "help", action: .requestHelp, botID: other.id, instructions: "Find sources", expectedOutput: "Sources")
        #expect(throws: (any Error).self) { try tools.perform(arguments(op)) }
        #expect(store.workflows[workflow.id]?.state == .running)
        #expect(store.workflows[workflow.id]?.tasks.count == 2 && store.workflows[workflow.id]?.operations == nil)
    }

    @Test func boundsAndCyclesLeaveGraphUnchanged() throws {
        let (_, initial, _, _, owner, other) = try fixture()
        let op = WorkflowOperation(operationID: "help", action: .requestHelp, botID: other.id, instructions: "Find sources", expectedOutput: "Sources")
        var workflow = initial; workflow.tasks[0].handoffDepth = 3
        #expect(throws: (any Error).self) { try workflow.apply(op, taskID: "work", members: [owner.id, other.id]) }
        #expect(workflow.tasks.count == 2 && workflow.operations == nil)
        workflow = initial
        for number in 0..<9 { workflow.tasks.insert(.init(id: "extra-\(number)", botID: owner.id, instructions: "Work", expectedOutput: "Output", dependencies: []), at: 1) }
        #expect(throws: (any Error).self) { try workflow.apply(op, taskID: "work", members: [owner.id, other.id]) }
        #expect(workflow.tasks.count == 11 && workflow.operations == nil)
        workflow = initial; workflow.tasks[0].dependencies = ["final"]
        #expect(throws: (any Error).self) { try workflow.apply(op, taskID: "work", members: [owner.id, other.id]) }
        #expect(workflow.tasks.count == 2 && workflow.operations == nil)
    }

    @Test func coordinatorCanAssignCodingWorkFromTheFinalTaskAndKeepsSynthesisLast() throws {
        let (store, initial, _, tools, owner, other) = try fixture()
        _ = try tools.perform(arguments(.init(operationID: "assign", action: .assign, botID: other.id, instructions: "Implement", expectedOutput: "Patch", role: .coding)))
        #expect(store.workflows[initial.id]?.tasks.first { $0.parentTaskID == "work" }?.role == .coding)
        var workflow = initial; workflow.tasks[0].state = .completed; workflow.tasks[1].state = .running
        let receipt = try workflow.apply(.init(operationID: "final-review", action: .requestReview, botID: other.id, instructions: "Review the final answer", expectedOutput: "Verdict"),
                                         taskID: "final", members: [owner.id, other.id])
        #expect(receipt.createdTaskIDs.count == 2 && workflow.tasks.count == 4)
        #expect(workflow.tasks.last?.botID == owner.id)
        #expect(workflow.tasks.last?.dependencies.contains(receipt.createdTaskIDs[0]) == true)
        #expect(workflow.tasks.last?.reviewTargetID == nil)
    }

    @Test func reportsAwaitTheFinishedReplyAndAReviewCannotBeBypassedByRefresh() throws {
        let (store, initial, _, tools, _, other) = try fixture()
        _ = try tools.perform(arguments(.init(operationID: "result", action: .reportResult, result: "Structured evidence")))
        #expect(store.workflows[initial.id]?.tasks.first?.state == .running)
        #expect(store.workflows[initial.id]?.tasks.first?.result == nil)
        var workflow = try #require(store.workflows[initial.id])
        let reply = ChatMessage(role: .assistant, content: "Finished", turnState: .finished)
        store.applyWorkflowCompletion(&workflow, index: 0, reply: reply)
        #expect(workflow.tasks[0].result == "Structured evidence")
        var review = WorkflowTask(id: "review", botID: other.id, instructions: "Review", expectedOutput: "Verdict", dependencies: ["work"], state: .running)
        review.reviewTargetID = "work"; review.reviewRound = 2
        workflow.tasks.insert(review, at: 1)
        store.applyWorkflowCompletion(&workflow, index: 1, reply: reply)
        #expect(workflow.tasks[1].state == .blocked && workflow.state == .paused, "no structured verdict")
        store.applyWorkflowCompletion(&workflow, index: 1, reply: reply)
        #expect(workflow.tasks[1].state == .blocked)
        try store.saveWorkflow(workflow)
        store.resumeWorkflow(workflow.id)
        #expect(store.workflows[workflow.id]?.state == .paused && store.errorMessage?.contains("Accept the review") == true)
        #expect(store.canAcceptWorkflowReview(workflow, task: workflow.tasks[1]))
        #expect(!store.canReassignWorkflowTask(workflow, task: workflow.tasks[1]), "a finished review is never sent again")
        store.acceptWorkflowReview(workflow.id, taskID: "review")
        #expect(store.workflows[workflow.id]?.tasks[1].state == .completed)
        #expect(store.workflows[workflow.id]?.tasks[1].reviewAcceptedByUser == true)
        #expect(store.workflows[workflow.id]?.tasks[1].resultArtifactID != nil)
        #expect(store.workflows[workflow.id]?.state == .paused)
    }

    @Test func restartDuringAPausedReviewKeepsTheReportAndBlocksTheUnconfirmedTask() throws {
        let (store, initial, _, tools, _, other) = try fixture()
        _ = try tools.perform(arguments(.init(operationID: "review", action: .requestReview, botID: other.id, instructions: "Check findings", expectedOutput: "Verdict")))
        _ = try tools.perform(arguments(.init(operationID: "result", action: .reportResult, result: "Evidence before crash")))
        store.save()
        let restored = AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let workflow = try #require(restored.workflows[initial.id])
        #expect(workflow.state == .paused && workflow.tasks[0].state == .blocked)
        #expect(workflow.tasks[0].reportedResult == "Evidence before crash")
        #expect(workflow.tasks.filter { $0.reviewTargetID != nil }.count == 1)
        #expect(workflow.operations?.count == 2)
        restored.restoreWorkflows()
        #expect(restored.workflows[initial.id]?.tasks.count == 3)
    }
}

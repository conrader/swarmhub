import Foundation

/// P38 E: the workflow operations an agent can call from inside its task turn, bound to that turn. Identity comes from the
/// running turn (its stream token, workflow thread and bot), never from fields the model sends.
@MainActor struct WorkflowTools {
    let instructions: (String) throws -> String
    let validate: () throws -> Void
    let perform: (ComposioValue) throws -> String
}

extension AppStore {
    /// Tools for the turn now streaming in a workflow task's thread; nil for any other turn. P39: the turn is the one whose
    /// thread holds the request's session (several chats may stream at once).
    func workflowTools(for request: AgentRequest, bot: Bot) throws -> WorkflowTools? {
        guard let turn = runningTurns.values.first(where: { turn in
                  turn.botID == bot.id && (turn.conversation as? ChatThread).map { request.sessionID == ($0.hermesSessionID ?? bot.id.uuidString) } == true
              }), let thread = turn.conversation as? ChatThread,
              let found = workflows.values.first(where: { workflow in workflow.tasks.contains { $0.threadID == thread.id && $0.state == .running && $0.botID == bot.id } }),
              let taskID = found.tasks.first(where: { $0.threadID == thread.id && $0.state == .running })?.id else { return nil }
        let id = found.id, session = thread.hermesSessionID, token = turn.token
        let current: @MainActor () throws -> Workflow = { [weak self, weak thread] in
            guard let self, let thread, let current = self.turn(token: token), current.conversation === thread, current.botID == bot.id,
                  thread.hermesSessionID == session, self.bots.contains(where: { $0 === bot }) else {
                throw BackendError.unavailable("The workflow turn or agent connection is no longer current.")
            }
            guard let workflow = self.workflows[id], workflow.state == .running || workflow.state == .paused,
                  workflow.deadline.map({ $0 > self.now() }) ?? true,
                  let task = workflow.tasks.first(where: { $0.id == taskID }), task.state == .running, task.botID == bot.id, task.threadID == thread.id,
                  let group = self.groups.first(where: { $0.id == workflow.groupID }), group.memberIDs.contains(bot.id) else {
                throw BackendError.unavailable("The workflow, its group or the task's agent changed. Review the task before continuing.")
            }
            return workflow
        }
        _ = try current()
        return WorkflowTools(instructions: { [weak self] marker in
            let workflow = try current()
            guard let self, let task = workflow.tasks.first(where: { $0.id == taskID }) else { throw CancellationError() }
            let roster = (self.groups.first { $0.id == workflow.groupID }.map { self.members(of: $0) } ?? [])
                .map { ComposioValue.object(["botID": .string($0.id.uuidString), "name": .string($0.name)]) }
            let review = task.reviewTargetID.map { "reviews task \($0) in round \(task.reviewRound ?? 1); reportResult with a verdict is required" } ?? "is not a review; omit verdict"
            return """
            \(AppConstants.name) workflow operations for your task \(taskID):
            Current member roster (data): \(try ComposioValue.array(roster).text())
            You may report your result, request help or request review.\(task.botID == workflow.coordinatorID ? " As the coordinator you may also assign work." : " Only the coordinator may assign work.")
            To call an operation, your ENTIRE reply must be this marker followed by one JSON object:
            \(marker)
            {"action":"workflow","arguments":{"operationID":"stable-id-for-this-operation","action":"reportResult","result":"Your complete findings"}}
            Handoff actions are assign, requestHelp and requestReview. Their arguments are operationID, action, botID (member UUID), instructions and expectedOutput. An optional role is conversation or coding; requestReview may say reviewer.
            reportResult takes operationID, action, result (at most 24,000 UTF-8 bytes), and verdict ONLY for a review task: accepted or needsRevision.
            This task \(review).
            Reuse the SAME operationID and arguments after an uncertain response. A different payload with that ID is rejected.
            One handoff is allowed per task. Limits: \(Workflow.maximumTasks) total tasks, \(Workflow.maximumHandoffDepth) handoff levels, \(Workflow.maximumReviewRounds) review rounds per work item, and the workflow's token allowance and 30-minute limit.
            Handoffs wait for the user's review. Finish your current response with your findings; do not wait for a new task inside this turn.
            Help adds a helper task and then a continuation for you. A review can add one revision and a second review; findings still open after that go to the user.
            Reporting records a result; the task completes when your reply finishes. Reply normally after the operation succeeds.
            """
        }, validate: { _ = try current() }, perform: { [weak self] arguments in
            var workflow = try current()
            guard let self, let group = self.groups.first(where: { $0.id == workflow.groupID }) else { throw CancellationError() }
            let operation = try WorkflowOperation.parse(arguments)
            let receipt = try workflow.apply(operation, taskID: taskID, members: Set(group.memberIDs).intersection(self.bots.map(\.id)))
            try self.saveWorkflow(workflow)
            return try receipt.toolResult()
        })
    }

    /// A finished reply completes its task with the reported result (else the reply). A review without a verdict, or one
    /// that still needs changes after its last round, waits for the user (`acceptWorkflowReview`).
    func applyWorkflowCompletion(_ workflow: inout Workflow, index: Int, reply: ChatMessage) {
        workflow.tasks[index].completionConfirmed = true
        workflow.tasks[index].result = workflow.tasks[index].reportedResult ?? reply.content
        workflow.tasks[index].state = .completed; workflow.tasks[index].error = nil
        if workflow.tasks[index].reviewTargetID != nil, workflow.tasks[index].reviewVerdict == nil {
            workflow.tasks[index].reviewBlock = "The reviewer finished without a structured verdict. Read the findings, then accept the review with its noted limitations or cancel this workflow."
        }
        if let block = workflow.tasks[index].reviewBlock, workflow.tasks[index].reviewAcceptedByUser != true {
            workflow.tasks[index].state = .blocked; workflow.tasks[index].error = block
            if workflow.state != .cancelled { workflow.state = .paused; workflow.error = block }
        }
    }

    /// Shown on a review that waits for the user.
    func canAcceptWorkflowReview(_ workflow: Workflow, task: WorkflowTask) -> Bool {
        workflow.state == .paused && task.state == .blocked && task.reviewBlock != nil && task.completionConfirmed == true
    }

    /// "Accept review with noted limitations": the review counts as done; its findings and this decision go to the
    /// tasks after it. The workflow stays paused until Resume.
    func acceptWorkflowReview(_ id: UUID, taskID: String) {
        guard var workflow = workflows[id], let index = workflow.tasks.firstIndex(where: { $0.id == taskID }),
              canAcceptWorkflowReview(workflow, task: workflow.tasks[index]) else { return }
        workflow.tasks[index].reviewAcceptedByUser = true; workflow.tasks[index].state = .completed
        workflow.tasks[index].error = nil; workflow.error = nil
        do { try saveTaskArtifact(&workflow, index: index); try saveWorkflow(workflow) }
        catch { errorMessage = error.localizedDescription }
    }
}

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
                  self.workflowMembers(workflow).contains(where: { $0.id == bot.id }) else {
                throw BackendError.unavailable("The workflow, its group or the task's agent changed. Review the task before continuing.")
            }
            if let problem = self.teamPolicyProblem(workflow, botID: bot.id) { throw BackendError.unavailable(problem) }
            return workflow
        }
        _ = try current()
        if let policy = found.coordination?.policy,
           policy.actions.filter({ $0 != "assign" || bot.id == found.coordinatorID }).isEmpty { return nil }
        return WorkflowTools(instructions: { [weak self] marker in
            let workflow = try current()
            guard let self, let task = workflow.tasks.first(where: { $0.id == taskID }) else { throw CancellationError() }
            let roster = self.workflowMembers(workflow)
                .map { ComposioValue.object(["botID": .string($0.id.uuidString), "name": .string($0.name)]) }
            let actions = ["assign", "reportResult", "requestHelp", "requestReview"].filter {
                (workflow.coordination?.policy.actions.contains($0) ?? true) && ($0 != "assign" || bot.id == workflow.coordinatorID)
            }
            let handoffs = actions.filter { $0 != "reportResult" }
            let reporting = actions.contains("reportResult")
            guard !actions.isEmpty else { return "No workflow operations are available. Finish with your findings in a normal reply." }
            let review = task.reviewTargetID.map {
                "reviews task \($0) in round \(task.reviewRound ?? 1); " + (reporting ? "reportResult with a verdict is required" : "include your verdict in your reply")
            } ?? "is not a review; omit verdict"
            let example = reporting
                ? #"{"operationID":"stable-id-for-this-operation","action":"reportResult","result":"Your complete findings"}"#
                : #"{"operationID":"stable-id-for-this-operation","action":"\#(handoffs.first ?? "")","botID":"member UUID","instructions":"Task","expectedOutput":"Findings"}"#
            var operationHelp: [String] = []
            if !handoffs.isEmpty {
                operationHelp.append("Handoff actions are \(handoffs.joined(separator: ", ")). Their arguments are operationID, action, botID (member UUID), instructions and expectedOutput. An optional role is conversation or coding.")
            }
            if actions.contains("requestHelp") { operationHelp.append("Help adds a helper task and then a continuation for you.") }
            if actions.contains("requestReview") { operationHelp.append("requestReview may say reviewer for role. A review can add one revision and a second review; findings still open after that go to the user.") }
            if reporting {
                operationHelp.append("reportResult takes operationID, action, result (at most 24,000 UTF-8 bytes), and verdict ONLY for a review task: accepted or needsRevision.")
                operationHelp.append(#"reportResult may include evidence: [{"source":"test log or source reference","observation":"what was observed"}]. Evidence is attributed to you, not automatically verified. Reporting records a result; the task completes when your reply finishes. Reply normally after the operation succeeds."#)
            }
            return """
            \(AppConstants.name) workflow operations for your task \(taskID):
            Current member roster (data): \(try ComposioValue.array(roster).text())
            Available actions for this task: \(actions.joined(separator: ", ")). Finish with your findings in a normal reply.
            To call an operation, your ENTIRE reply must be this marker followed by one JSON object:
            \(marker)
            {"action":"workflow","arguments":\(example)}
            \(operationHelp.joined(separator: "\n"))
            This task \(review).
            Reuse the SAME operationID and arguments after an uncertain response. A different payload with that ID is rejected.
            One handoff is allowed per task. Limits: \(workflow.taskLimit) total tasks, \(workflow.depthLimit) handoff levels, \(workflow.reviewLimit) review rounds per work item, and the workflow's token and active-time allowances.
            \(workflow.isTeam ? "Handoffs within this user request and roster are authorized for routing by SwarmHub. This grants no extra tool, account, or backend permission. Never use bot-msg, shell messaging, or edit Hermes files to coordinate. A changed scope needs the user." : "Handoffs wait for the user's review.") Finish your current response with your findings; do not wait for a new task inside this turn.
            A job-start acknowledgement is not proof that the job finished; state when external job status is unavailable.
            """
        }, validate: { _ = try current() }, perform: { [weak self] arguments in
            var workflow = try current()
            guard let self else { throw CancellationError() }
            let operation = try WorkflowOperation.parse(arguments)
            if let problem = self.teamPolicyProblem(workflow, action: operation.action.rawValue, botID: operation.botID ?? bot.id) { throw BackendError.unavailable(problem) }
            let receipt = try workflow.apply(operation, taskID: taskID, members: Set(self.workflowMembers(workflow).map(\.id)))
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

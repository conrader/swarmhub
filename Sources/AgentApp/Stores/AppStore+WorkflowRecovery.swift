import Foundation

/// P38 D: getting a workflow past a task that did not finish. Refresh reads the task's thread from its server (P16
/// reconcile) and settles a reply that turned out finished. Reassign moves a task that certainly never reached its
/// server to another member (or sends it again); uncertain work is never handed to someone else.
extension AppStore {
    func refreshWorkflowTask(_ id: UUID, taskID: String) async {
        guard let workflow = workflows[id], let task = workflow.tasks.first(where: { $0.id == taskID }), task.state == .blocked,
              let thread = workflowThread(task.threadID, botID: task.botID) else { return }
        await reconcile(thread, reason: .refresh)
        settleWorkflows()
    }

    /// Only a paused workflow's queued task, or a blocked one whose replies are all certainly unsent.
    func canReassignWorkflowTask(_ workflow: Workflow, task: WorkflowTask) -> Bool {
        // P38 E: a task whose reply finished (a review waiting for the user) is never sent again.
        guard workflow.state == .paused, task.state == .queued || task.state == .blocked, task.completionConfirmed != true else { return false }
        guard let thread = workflowThread(task.threadID, botID: task.botID) else {
            // A removed assignee could still be working remotely: only work that was never sent moves.
            return task.state == .queued || task.replyID == nil
        }
        guard !(isStreaming && streamingConversation === thread) else { return false }
        return thread.messages.filter { $0.role == .assistant && $0.presentation == .text }
            .allSatisfy { $0.turnState == .notSent && $0.metadata[TurnKey.ambiguous] != "1" }
    }

    /// The task starts over in a new thread for `botID`; the old thread can no longer send.
    @discardableResult func reassignWorkflowTask(_ id: UUID, taskID: String, botID: UUID) -> Bool {
        guard var workflow = workflows[id], let index = workflow.tasks.firstIndex(where: { $0.id == taskID }),
              let group = groups.first(where: { $0.id == workflow.groupID }), group.memberIDs.contains(botID),
              bots.contains(where: { $0.id == botID }), canReassignWorkflowTask(workflow, task: workflow.tasks[index]) else {
            errorMessage = "Only a task that certainly was not sent can be reassigned. Refresh uncertain work from its server first."; return false
        }
        let previous = workflow.tasks[index]
        if previous.replyID != nil || workflowThread(previous.threadID, botID: previous.botID) != nil {
            workflow.tasks[index].previousThreadIDs = (previous.previousThreadIDs ?? []) + [previous.threadID]
            workflow.tasks[index].threadID = UUID()
        }
        workflow.tasks[index].botID = botID; workflow.tasks[index].state = .queued; workflow.tasks[index].error = nil
        workflow.budget.reserved = max(0, workflow.budget.reserved - previous.reservation)
        workflow.tasks[index].reservation = 0; workflow.tasks[index].replyID = nil
        workflow.error = nil
        do { try saveWorkflow(workflow); return true } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Paused only: the token allowance (8,000–1,000,000).
    func setWorkflowAllowance(_ id: UUID, tokens: Int) {
        guard var workflow = workflows[id], workflow.state == .paused else { return }
        workflow.budget.tokenLimit = min(1_000_000, max(8_000, tokens))
        commitWorkflow(workflow)
    }
}

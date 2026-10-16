import Foundation
import SwarmHubCoordination

extension AppStore {
    func restoreTeamWorkflow(_ saved: Workflow) {
        var workflow = saved
        if !workflow.isFinished {
            workflow.coordination?.resumeAfterRecovery = saved.state == .running || saved.coordination?.resumeAfterRecovery == true
            workflow.coordination?.activeSince = nil
            workflow.state = .paused
            workflow.error = "Waiting to check remote work before continuing."
            for index in workflow.tasks.indices where workflow.tasks[index].state == .running {
                workflow.tasks[index].state = .blocked
                workflow.tasks[index].delivery?.record(.uncertain, at: now())
            }
        }
        workflows[workflow.id] = workflow
        if let team = workflow.coordination, let origin = workflowDestination(workflow),
           !origin.messages.contains(where: { $0.id == team.originMessageID }) {
            origin.messages.append(ChatMessage(id: team.originMessageID, role: .user, content: workflow.request,
                createdAt: workflow.createdAt, metadata: ["teamOrigin": workflow.id.uuidString]))
        }
        for task in workflow.tasks where task.delivery != nil {
            guard let bot = bots.first(where: { $0.id == task.botID }), let delivery = task.delivery else { continue }
            ensureWorkflowThread(task.threadID, workflow: workflow, bot: bot, role: task.role)
            guard let thread = workflowThread(task.threadID, botID: task.botID) else { continue }
            if thread.hermesSessionID == nil { thread.hermesSessionID = delivery.sessionID }
            if !thread.messages.contains(where: { $0.id == delivery.replyID }) {
                thread.messages.append(ChatMessage(role: .user, content: delivery.envelope.payload, createdAt: delivery.events.first?.at ?? workflow.createdAt))
                thread.messages.append(ChatMessage(id: delivery.replyID, role: .assistant, content: "", createdAt: delivery.events.first?.at ?? workflow.createdAt,
                    metadata: [TurnKey.ambiguous: "1"], turnState: .incomplete))
            }
            if let runID = delivery.runID { thread.messages.first { $0.id == delivery.replyID }?.metadata[TurnKey.run] = runID }
        }
        projectWorkflowResult(workflow)
    }

    /// Read-only backend reconciliation first. Missing sessions/history never justify automatic resend.
    func recoverTeams() async {
        guard !teamRecovering, !turns.pathDown, ownsTeamDispatcher() else { return }
        teamRecovering = true
        defer { teamRecovering = false; dispatchWorkflows() }
        for saved in workflows.values.filter({ $0.isTeam && !$0.isFinished }) {
            guard saved.coordination?.policy.ownerDeviceID == teamDeviceID else { continue }
            for task in saved.tasks where task.delivery != nil && task.state != .completed && task.state != .cancelled {
                guard let thread = workflowThread(task.threadID, botID: task.botID), isIdle(thread) else { continue }
                _ = await reconcile(thread, reason: .refresh)

            }
            settleWorkflows()
            guard var workflow = workflows[saved.id], workflow.coordination?.resumeAfterRecovery == true,
                  !workflow.tasks.contains(where: { $0.state == .blocked }), teamPolicyProblem(workflow) == nil else { continue }
            workflow.coordination?.resumeAfterRecovery = false
            workflow.state = .running; workflow.error = nil
            commitWorkflow(workflow)
        }
    }

    /// Shared by manual refresh, launch and bounded read-only polling. No missing history can prove non-delivery.
    func reconcileTeamOutcome(_ conversation: any Conversation) {
        guard let saved = teamWorkflow(in: conversation), let task = saved.tasks.first(where: { $0.threadID == conversation.id }),
              let row = conversation.messages.first(where: { $0.id == task.replyID }), !row.isStreaming else { return }
        if task.delivery?.state != .failed && row.turnState == .notSent {
            row.turnState = .incomplete; row.metadata[TurnKey.ambiguous] = "1"
        }
        if row.content.contains("[[SWARMHUB_APP_REQUEST_") {
            row.content = task.reportedResult ?? ""; row.turnState = .incomplete; row.metadata[TurnKey.ambiguous] = "1"
        }
        settleWorkflows()
        guard !teamRecovering, var workflow = workflows[saved.id], workflow.coordination?.resumeAfterRecovery == true,
              !workflow.tasks.contains(where: { $0.state == .blocked }), teamPolicyProblem(workflow) == nil else { return }
        workflow.coordination?.resumeAfterRecovery = false; workflow.state = .running; workflow.error = nil
        commitWorkflow(workflow); dispatchWorkflows()
    }

    func suspendTeamClock() {
        for var workflow in workflows.values where workflow.isTeam && workflow.coordination?.activeSince != nil {
            stopTeamClock(&workflow); commitWorkflow(workflow)
        }
    }

    func cancelQueuedTeamWork(_ id: UUID) {
        guard var workflow = workflows[id], workflow.isTeam, ownsTeamDispatcher() else { return }
        workflow.state = .paused; workflow.coordination?.resumeAfterRecovery = false
        for index in workflow.tasks.indices where workflow.tasks[index].state == .queued {
            workflow.tasks[index].state = .cancelled
            workflow.tasks[index].delivery?.record(.cancelledBeforeSend, at: now())
        }
        workflow.error = "Queued work cancelled. Work already sent may still finish."
        commitWorkflow(workflow)
    }

    func confirmTeamEvidence(_ id: UUID, taskID: String) {
        guard var workflow = workflows[id], ownsTeamDispatcher(), let index = workflow.tasks.firstIndex(where: { $0.id == taskID }),
              workflow.tasks[index].completionConfirmed == true, workflow.tasks[index].reviewBlock == nil else { return }
        workflow.tasks[index].verifiedByUser = true; workflow.tasks[index].state = .completed; workflow.tasks[index].error = nil
        commitWorkflow(workflow)
    }

    func notifyTeamBlocker(_ workflow: Workflow) {
        guard var saved = workflows[workflow.id], saved.state == .paused, let error = saved.error,
              let reporting = saved.coordination?.reporting, reporting.notifyBlockers,
              reporting.isQuiet(at: now()) == false, ownsTeamDispatcher(),
              let coordinator = bots.first(where: { $0.id == saved.coordinatorID }) else { return }
        let event = "blocker:" + error
        guard saved.coordination?.notificationEvents.contains(event) == false else { return }
        saved.coordination?.notificationEvents.insert(event)
        do { try saveWorkflow(saved) } catch { errorMessage = error.localizedDescription; return }
        notifyIfNeeded(bot: coordinator, message: error)
    }

    func notifyTeamResult(_ workflow: Workflow) {
        guard var saved = workflows[workflow.id], let reporting = saved.coordination?.reporting,
              reporting.notifyResults, reporting.isQuiet(at: now()) == false, ownsTeamDispatcher(),
              saved.coordination?.notificationEvents.contains("result") == false,
              let coordinator = bots.first(where: { $0.id == workflow.coordinatorID }) else { return }
        saved.coordination?.notificationEvents.insert("result")
        do { try saveWorkflow(saved) } catch { errorMessage = error.localizedDescription; return }
        notifyIfNeeded(bot: coordinator, message: saved.tasks.last?.result ?? "Team work finished.")
    }
}

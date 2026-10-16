import Foundation
import SwarmHubCoordination

extension AppStore {
    var teamDeviceID: String {
        if let value = defaults.string(forKey: "teamCoordinatingDevice") { return value }
        let value = UUID().uuidString; defaults.set(value, forKey: "teamCoordinatingDevice"); return value
    }
    func ownsTeamDispatcher() -> Bool {
        persistenceEnabled && teamLease.acquire(at: fileURL.deletingLastPathComponent().appending(path: "coordination.lock"))
    }
    func teamIdentity(_ bot: Bot) -> TeamIdentity {
        .init(botID: bot.id, connection: connection(of: bot), profile: bot.backend.rawValue + ":" + (bot.backend == .openClaw ? (bot.openClaw?.agentID ?? "unbound") : profile(of: bot)))
    }
    func workflowMembers(_ workflow: Workflow) -> [Bot] {
        if let policy = workflow.coordination?.policy {
            let liveGroup = groups.first { $0.id == workflow.groupID }
            return bots.filter { bot in policy.members.contains(teamIdentity(bot)) && (liveGroup?.memberIDs.contains(bot.id) ?? true) }
        }
        return groups.first { $0.id == workflow.groupID }.map { members(of: $0) } ?? []
    }
    func workflowDestination(_ workflow: Workflow) -> (any Conversation)? {
        if let group = groups.first(where: { $0.id == workflow.groupID }) { return group }
        if let bot = bots.first(where: { $0.id == workflow.groupID }) { return bot }
        return bots.flatMap(\.threads).first { $0.id == workflow.groupID }
    }
    func teamWorkflow(in conversation: any Conversation) -> Workflow? {
        guard let thread = conversation as? ChatThread, let workflow = workflows[thread.parentMessageID], workflow.isTeam else { return nil }
        return workflow
    }
    func isTeamThread(_ conversation: any Conversation) -> Bool { teamWorkflow(in: conversation) != nil }
    func intendedTeamReply(in conversation: any Conversation) -> UUID? {
        teamWorkflow(in: conversation)?.tasks.first { $0.threadID == conversation.id }?.delivery?.replyID
    }
    func workflowSessionID(_ threadID: UUID) -> String { sessionNamespace + "agentapp_workflow_" + threadID.uuidString.lowercased() }

    func teamPolicyProblem(_ workflow: Workflow, action: String = "requestHelp", botID: UUID? = nil) -> String? {
        guard let team = workflow.coordination else { return nil }
        guard workflowDestination(workflow) != nil else { return "The originating conversation was removed. New work is paused." }
        guard ownsTeamDispatcher() else { return "Another SwarmHub window or process owns coordination. Reopen this instance after it closes." }
        guard team.policy.ownerDeviceID == teamDeviceID else { return "Waiting for the coordinating device. This device can inspect the saved results." }
        guard let identity = workflowMembers(workflow).first(where: { $0.id == (botID ?? workflow.coordinatorID) }).map(teamIdentity),
              team.policy.allows(action, identity: identity, at: now()) else { return "The delegation permission expired, was revoked, or an agent connection changed. Review the team before continuing." }
        guard team.limits.isValid else { return "Review the team's limits before continuing." }
        return nil
    }

    /// A user-selected peer starts a task in its own normal backend session. The coordinator receives its result as a dependency.
    @discardableResult func startTeamRequest(_ text: String, origin: any Conversation, coordinator: Bot, recipient: Bot,
                                            roster: [Bot], display: String? = nil) -> Bool {
        guard ownsTeamDispatcher(), roster.contains(where: { $0.id == recipient.id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Team work needs this SwarmHub instance to own coordination and a current recipient."; return false
        }
        guard text.utf8.count <= 12_000 else { errorMessage = "Keep the team request within 12,000 UTF-8 bytes; put reference material in shared context."; return false }
        let user = ChatMessage(role: .user, content: display ?? text)
        let request = text
        let identities = roster.map(teamIdentity)
        guard Set(identities.map { $0.connection + "|" + $0.profile }).count == identities.count else {
            errorMessage = "Two team members use the same backend identity. Choose one of them."; return false
        }
        let policy = TeamPolicy(originID: origin.id, decision: request, members: identities, ownerDeviceID: teamDeviceID)
        var workflow = Workflow(id: UUID(), groupID: origin.id, coordinatorID: coordinator.id, request: request, createdAt: now(), state: .running,
            tasks: [.init(id: "work", botID: recipient.id, instructions: request, expectedOutput: "Answer the request with evidence and unresolved limitations. Ask a listed peer for help or review when useful.", dependencies: []),
                    .init(id: "synthesis", botID: coordinator.id, instructions: "Consolidate the findings for the user. Preserve disagreements and distinguish reported results from verified outcomes.", expectedOutput: "One consolidated answer", dependencies: ["work"])],
            budget: .init(id: UUID(), tokenLimit: Self.workflowDefaultBudget))
        workflow.coordination = TeamCoordination(policy: policy, originMessageID: user.id)
        user.metadata["teamOrigin"] = workflow.id.uuidString
        do { try saveWorkflow(workflow) } catch { errorMessage = error.localizedDescription; return false }
        origin.messages.append(user); objectWillChange.send(); save(); dispatchWorkflows()
        return true
    }

    func authorizeTeamWorkflow(_ id: UUID) {
        guard var workflow = workflows[id], workflow.state == .paused, ownsTeamDispatcher() else { return }
        if let owner = workflow.coordination?.policy.ownerDeviceID, owner != teamDeviceID {
            errorMessage = "This task belongs to another coordinating installation. Inspect it here or start a separate request; automatic takeover is unavailable."; return
        }
        let roster = groups.first(where: { $0.id == workflow.groupID }).map { members(of: $0) }
            ?? bots.filter { bot in workflow.coordination?.policy.members.contains(where: { $0.botID == bot.id }) == true }
        guard roster.contains(where: { $0.id == workflow.coordinatorID }) else { return }
        let old = workflow.coordination
        var policy = TeamPolicy(originID: workflow.groupID, decision: workflow.request, members: roster.map(teamIdentity), ownerDeviceID: teamDeviceID)
        policy.version = (old?.policy.version ?? 0) + 1
        workflow.coordination = old ?? TeamCoordination(policy: policy, originMessageID: UUID())
        workflow.coordination?.policy = policy; workflow.deadline = nil
        commitWorkflow(workflow)
    }

    func revokeTeamPolicy(_ id: UUID) {
        guard var workflow = workflows[id], ownsTeamDispatcher() else { return }
        workflow.coordination?.policy.revokedAt = now(); workflow.coordination?.policy.version += 1
        workflow.state = .paused; workflow.error = "Delegation permission revoked. Work already sent may still finish."
        commitWorkflow(workflow)
    }

    func interveneInTeam(_ id: UUID, text: String) {
        guard var workflow = workflows[id], !workflow.isFinished, workflow.isTeam,
              ownsTeamDispatcher(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workflow.coordination?.steering.append(String(text.prefix(12_000)))
        do { try saveWorkflow(workflow) } catch { errorMessage = error.localizedDescription; return }
        workflowDestination(workflow)?.messages.append(ChatMessage(role: .user, content: text, metadata: ["teamSteer": id.uuidString]))
        save()
        // New instructions affect queued tasks. A sent task is steered only through the ordinary supported UI.
    }
}

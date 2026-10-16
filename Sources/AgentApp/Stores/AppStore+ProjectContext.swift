import Foundation
import SwarmHubCoordination

extension AppStore {
    func restoreProjectFacts() {
        guard hasLedger else { return }
        do { projectFacts = try journal().records(ProjectFact.self, kind: "projectFact") }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func saveProjectFact(_ fact: ProjectFact) -> Bool {
        guard ownsTeamDispatcher(), !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fact.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fact.text.utf8.count <= 12_000, fact.source.utf8.count <= 2_000, !fact.readers.isEmpty else {
            errorMessage = "A project fact needs text, a source and at least one reader."; return false
        }
        if let previousID = fact.supersedes {
            guard let previous = projectFacts.first(where: { $0.id == previousID }), previous.projectID == fact.projectID,
                  fact.revision == previous.revision + 1 else { errorMessage = "The earlier fact or revision changed."; return false }
        }
        do {
            try journal().put(fact, kind: "projectFact", id: fact.id.uuidString)
            projectFacts.removeAll { $0.id == fact.id }; projectFacts.append(fact)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Re-evaluate readers against current connections at delivery time. An unreadable replacement cannot hide a readable fact.
    func projectContext(projectID: UUID, for bot: Bot) -> String {
        let identity = teamIdentity(bot)
        let readable = projectFacts.filter { $0.projectID == projectID && $0.readers.contains(identity) }
        let replaced = Set(readable.compactMap(\.supersedes))
        let facts = readable.filter { !replaced.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        return facts.map { "[\($0.kind.rawValue), \($0.status.rawValue), revision \($0.revision), owner \($0.owner), source \($0.source), at \($0.createdAt.ISO8601Format())]\n\($0.text)" }.joined(separator: "\n\n")
    }

    func editTeam(_ id: UUID, change: (inout TeamCoordination) -> Void) {
        guard var workflow = workflows[id], workflow.state == .paused, var team = workflow.coordination, ownsTeamDispatcher() else { return }
        change(&team)
        guard team.limits.isValid, team.limits.tasks >= workflow.tasks.count,
              team.reporting.timeZoneID.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            errorMessage = "Use valid limits and an IANA timezone, such as Europe/Warsaw."; return
        }
        team.policy.version += 1
        workflow.coordination = team; commitWorkflow(workflow)
    }

    func interveneInTeamTask(_ id: UUID, taskID: String, text: String) {
        guard var workflow = workflows[id], workflow.isTeam, ownsTeamDispatcher(), !text.isEmpty,
              let index = workflow.tasks.firstIndex(where: { $0.id == taskID && $0.state == .queued }) else { return }
        let instructions = workflow.tasks[index].instructions + "\nAdditional user instruction: " + text
        guard instructions.utf8.count <= 12_000 else { errorMessage = "This task's instructions are too long."; return }
        workflow.tasks[index].instructions = instructions
        do { try saveWorkflow(workflow) } catch { errorMessage = error.localizedDescription; return }
        workflowDestination(workflow)?.messages.append(ChatMessage(role: .user, content: text, metadata: ["teamSteer": id.uuidString, "teamTask": taskID]))
        save()
    }

    func openWorkflowTask(_ task: WorkflowTask) {
        guard let bot = bots.first(where: { $0.id == task.botID }), workflowThread(task.threadID, botID: bot.id) != nil else { return }
        selectedBot = bot; selectedGroup = nil; openThreadID = task.threadID
    }
}

import Foundation

/// P38 D: a delegated child task as the ledger keeps it (kind `subagent`), so its card can still open the child's
/// transcript after a relaunch.
struct ChildTaskRecord: Codable, Sendable {
    var botID: UUID
    var task: SubAgentTask
}

extension AppStore {
    static let childTaskKind = "subagent"

    /// One card per child: a start and its finish update the same row and the same entry. A finished child is never
    /// set back to running by a late start event. `row: false` (group turns) keeps only the entry, as before.
    func upsertSubAgent(_ task: SubAgentTask, bot: Bot, in conversation: any Conversation, row: Bool = true) {
        var task = task
        if let index = subAgentTasks[bot.id]?.firstIndex(where: { $0.id == task.id }), let previous = subAgentTasks[bot.id]?[index] {
            if [.completed, .failed].contains(previous.status), [.queued, .running].contains(task.status) { return }
            task.sessionID = task.sessionID ?? previous.sessionID; task.runID = task.runID ?? previous.runID
            subAgentTasks[bot.id]?[index] = task
        } else { subAgentTasks[bot.id, default: []].append(task) }
        if row {
            let metadata = ["detail": task.detail, "status": task.status.rawValue, "taskID": task.id.uuidString, "botID": bot.id.uuidString]
            if let existing = conversation.messages.first(where: { $0.presentation == .delegation && $0.metadata["taskID"] == task.id.uuidString }) {
                existing.content = task.title; existing.metadata = metadata
            } else { conversation.messages.append(ChatMessage(role: .assistant, content: task.title, presentation: .delegation, metadata: metadata)) }
            objectWillChange.send()
        }
        guard persistenceEnabled else { return }
        do { try journal().put(ChildTaskRecord(botID: bot.id, task: task), kind: Self.childTaskKind, id: task.id.uuidString) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Launch: the children the ledger remembers. One still running when the app quit stays as the server last
    /// reported it; its card can open the transcript to check.
    func restoreChildTasks() {
        guard persistenceEnabled, hasLedger else { return }
        do {
            for record in try journal().records(ChildTaskRecord.self, kind: Self.childTaskKind) where bots.contains(where: { $0.id == record.botID }) {
                if let index = subAgentTasks[record.botID]?.firstIndex(where: { $0.id == record.task.id }) { subAgentTasks[record.botID]?[index] = record.task }
                else { subAgentTasks[record.botID, default: []].append(record.task) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func childTask(for message: ChatMessage) -> (bot: Bot, task: SubAgentTask)? {
        guard let botID = message.metadata["botID"].flatMap(UUID.init(uuidString:)), let taskID = message.metadata["taskID"].flatMap(UUID.init(uuidString:)),
              let bot = bots.first(where: { $0.id == botID }), let task = subAgentTasks[botID]?.first(where: { $0.id == taskID }) else { return nil }
        return (bot, task)
    }

    /// The child's transcript as plain text (GET only).
    func childTranscript(_ task: SubAgentTask, bot: Bot) async throws -> String {
        guard let sessionID = task.sessionID else { throw BackendError.unavailable("The server did not name this child's session.") }
        let rows = try await backend(for: bot).loadMessages(sessionID: sessionID)
        return rows.isEmpty ? "The child's session has no messages yet." : rows.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")
    }

    /// Stop is offered only for a Hermes child the server named a run for, on a box with run control.
    func canStopChild(_ task: SubAgentTask, bot: Bot) async -> Bool {
        guard bot.backend == .hermes, task.runID != nil, task.status == .running, let backend = try? backend(for: bot) else { return false }
        return (try? await backend.sessionTransport()) == .nativeSessions
    }

    func stopChild(_ task: SubAgentTask, bot: Bot) async throws -> String {
        guard let runID = task.runID else { throw BackendError.unavailable("The server did not name this child's run.") }
        _ = try await backend(for: bot).requestStop(.serverRun(runID))
        return "Stop requested. The child keeps its state until the server reports how it ended."
    }
}

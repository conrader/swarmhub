import Foundation

/// P32 2: what the Overview's "Delegated tasks" lists. Hermes runs sub-agents through its `delegate_task` tool, so each
/// such step in this chat's replies is one task (newest first); `subagent.*` stream events, if a server sends them,
/// are listed after them.
struct DelegatedTask: Identifiable, Equatable {
    enum Status: String { case running = "Running", done = "Done", failed = "Failed" }
    let id: String; let goal: String; let startedAt: Date; let finishedAt: Date?; let status: Status

    static let tool = "delegate_task"
    static let limit = 20

    static func tasks(in messages: [ChatMessage]) -> [DelegatedTask] {
        let found = messages.filter { $0.role == .assistant }.flatMap { message in
            (message.activity?.steps ?? []).enumerated().filter { $0.element.name == tool }.map { index, step in
                DelegatedTask(id: "\(message.id.uuidString)-\(index)", goal: step.preview ?? "Delegated task", startedAt: step.startedAt,
                              finishedAt: step.finishedAt,
                              status: ActivityCopy.isRunning(step, streaming: message.isStreaming) ? .running : step.failed ? .failed : .done)
            }
        }
        return Array(found.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    static func tasks(in bot: Bot) -> [DelegatedTask] { tasks(in: bot.messages + bot.threads.flatMap(\.messages)) }

    /// "Started 14:02 · finished after 3 m 0 s", "Started 14:02 · still running".
    var detail: String {
        let started = "Started \(startedAt.formatted(date: .omitted, time: .shortened))"
        switch status {
        case .running: return "\(started) · still running"
        case .done, .failed:
            guard let finishedAt else { return started }
            return "\(started) · \(status == .failed ? "failed" : "finished") after \(ActivityCopy.duration(finishedAt.timeIntervalSince(startedAt)))"
        }
    }
}

/// P32 2, 3: the Overview's honest copy for what the app does and does not see.
enum OverviewCopy {
    static let delegatedEmpty = "Delegated tasks from this chat appear here."
    static let memoryOnBox = "This agent's memory lives on its box."
    static let memoryImported = "Imported with this agent. What it remembers now lives on its box."
}

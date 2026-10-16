import Foundation
import SwarmHubCoordination

/// P38 D: a token allowance for a workflow. Work reserves an estimate before it is sent; the reply settles it.
struct RunBudget: Codable, Sendable, Equatable {
    var id: UUID
    var tokenLimit: Int
    var reserved = 0
    var spent = 0
    mutating func reserve(_ amount: Int) throws {
        guard amount >= 0, amount <= tokenLimit - spent - reserved else { throw BackendError.unavailable("This workflow reached its token allowance. Raise the allowance to continue.") }
        reserved += amount
    }
    mutating func settle(reservation: Int, actual: Int) { reserved = max(0, reserved - reservation); spent += max(0, actual) }
}

/// P38 D: one step of a workflow, answered by one group member in a thread of its own.
struct WorkflowTask: Codable, Identifiable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case queued, running, completed, blocked, cancelled }
    var id: String
    var botID: UUID
    var instructions: String
    var expectedOutput: String
    var dependencies: [String]
    var role: ModelRole = .conversation
    var state: State = .queued
    var threadID: UUID = UUID()
    var result: String?
    var resultArtifactID: UUID?
    var error: String?
    var reservation = 0
    /// Tokens already charged for this task; a later settlement replaces this amount instead of adding to it.
    var chargedTokens: Int?
    /// The reply row this task waits for (set when it is sent).
    var replyID: UUID?
    /// Threads this task used before it was reassigned; they can no longer send.
    var previousThreadIDs: [UUID]?
    /// P38 E: handoffs (`WorkflowOperations.swift`): the task that asked for this one and how deep the chain is.
    var parentTaskID: String?
    var handoffDepth: Int?
    /// A review task: the task it reviews, the first work of its chain, and its round (1 or 2).
    var reviewTargetID: String?
    var reviewRootID: String?
    var reviewRound: Int?
    /// What the agent reported with reportResult (used as the result once its reply finishes) and a reviewer's verdict.
    var reportedResult: String?
    var reviewVerdict: WorkflowOperation.Verdict?
    /// Set when a review needs the user: the task stays blocked until "Accept review with noted limitations".
    var reviewBlock: String?
    var completionConfirmed: Bool?
    var reviewAcceptedByUser: Bool?
    var delivery: TeamDelivery?
    var evidence: [TeamEvidence]?
    var verifiedByUser: Bool?
}

/// P38 D: a group request split by a coordinator into dependent tasks. Planning ends paused: nothing runs before the
/// user approves the plan. Kept in the ledger (kind `workflow`); the result is a saved document plus one group message.
struct Workflow: Codable, Identifiable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case planning, running, paused, completed, cancelled }
    static let maximumTasks = 12, deadline: TimeInterval = 1800
    var id: UUID
    var groupID: UUID
    var coordinatorID: UUID
    var request: String
    var createdAt: Date = .now
    var deadline: Date?
    var state: State = .planning
    var tasks: [WorkflowTask] = []
    var budget: RunBudget
    var artifactID: UUID?
    var error: String?
    /// The coordinator's planning thread and the reply row the plan is read from.
    var planThreadID: UUID?
    var planReplyID: UUID?
    /// P38 E: every handoff and report, committed with the graph so a repeated tool call creates nothing twice.
    var operations: [WorkflowOperationReceipt]?
    var coordination: TeamCoordination?

    var isActive: Bool { state == .planning || state == .running }
    var isFinished: Bool { state == .completed || state == .cancelled }

    var stateLabel: String {
        switch state {
        case .planning: "Planning"
        case .running: coordination != nil && !tasks.contains(where: { $0.state == .running }) ? "Waiting to continue" : "Running"
        case .paused: coordination != nil ? "Paused" : tasks.isEmpty ? "Paused" : (tasks.allSatisfy { $0.state == .queued } ? "Waiting for your approval" : "Paused")
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    /// 1–12 tasks with unique IDs, each assigned to a member, with instructions, an expected output and dependencies
    /// that exist and form no cycle.
    static func validate(_ tasks: [WorkflowTask], members: Set<UUID>, maximum: Int = maximumTasks) throws {
        guard !tasks.isEmpty, tasks.count <= maximum, Set(tasks.map(\.id)).count == tasks.count else {
            throw BackendError.unavailable("A workflow needs 1–\(maximum) tasks with unique IDs.")
        }
        let ids = Set(tasks.map(\.id)); var done = Set<String>()
        for task in tasks {
            guard members.contains(task.botID), !task.instructions.isEmpty, task.instructions.count <= 12_000,
                  !task.expectedOutput.isEmpty, task.dependencies.allSatisfy(ids.contains), !task.dependencies.contains(task.id) else {
                throw BackendError.unavailable("The workflow has an unavailable assignee, missing instructions or an invalid dependency.")
            }
        }
        while done.count < tasks.count {
            let ready = tasks.filter { !done.contains($0.id) && $0.dependencies.allSatisfy(done.contains) }
            guard !ready.isEmpty else { throw BackendError.unavailable("The workflow contains a dependency cycle.") }
            done.formUnion(ready.map(\.id))
        }
    }
}

/// The coordinator's plan as JSON. `role` is free text: `coding` opens a coding thread, anything else a conversation.
struct WorkflowProposal: Decodable {
    struct Task: Decodable {
        var id: String
        var botID: UUID
        var instructions: String
        var expectedOutput: String
        var dependencies: [String]?
        var role: String?
    }
    var tasks: [Task]

    /// The first `{` to the last `}` of the reply, so a fenced or introduced plan still reads.
    static func parse(_ reply: String) throws -> WorkflowProposal {
        guard reply.utf8.count <= 100_000, let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw BackendError.unavailable("The coordinator did not return a plan.")
        }
        do { return try JSONDecoder().decode(WorkflowProposal.self, from: Data(reply[start...end].utf8)) }
        catch { throw BackendError.unavailable("The coordinator's plan could not be read: \(error.localizedDescription)") }
    }

    func validated(members: Set<UUID>) throws -> [WorkflowTask] {
        let result = tasks.map {
            WorkflowTask(id: $0.id, botID: $0.botID, instructions: $0.instructions, expectedOutput: $0.expectedOutput,
                         dependencies: $0.dependencies ?? [], role: $0.role?.lowercased() == "coding" ? .coding : .conversation)
        }
        try Workflow.validate(result, members: members, maximum: Workflow.maximumTasks - 1)
        return result
    }
}

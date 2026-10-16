import CryptoKit
import Foundation
import SwarmHubCoordination

/// P38 E: what an agent working on a workflow task may ask for: assign work (coordinator only), request help, request
/// review, or report its result. Parsed from the tool envelope (`ConnectedAppsChat`), never trusted for identity: the
/// task and member come from the running turn (`AppStore.workflowTools`).
struct WorkflowOperation: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable { case assign, requestHelp, requestReview, reportResult }
    enum Verdict: String, Codable, Sendable { case accepted, needsRevision }
    /// `reviewer` is accepted for a review request; the review task itself runs as a conversation.
    enum Role: String, Codable, Sendable { case conversation, coding, reviewer }
    let operationID: String
    let action: Action
    var botID: UUID?
    var instructions: String?
    var expectedOutput: String?
    var result: String?
    var verdict: Verdict?
    var role: Role?
    var evidence: [TeamEvidence]?

    static let maximumReport = 24_000, maximumInstructions = 12_000, maximumExpected = 2_000

    static func parse(_ value: ComposioValue) throws -> Self {
        guard let fields = value.object,
              Set(fields.keys).isSubset(of: ["operationID", "action", "botID", "instructions", "expectedOutput", "result", "verdict", "role", "evidence"]) else {
            throw BackendError.unavailable("Unknown workflow operation fields.")
        }
        let operation: Self
        do { operation = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
        catch { throw BackendError.unavailable("The workflow operation could not be read.") }
        try operation.validate()
        let allowed: Set<String> = operation.action == .reportResult
            ? ["operationID", "action", "result", "verdict", "evidence"]
            : ["operationID", "action", "botID", "instructions", "expectedOutput", "role"]
        guard Set(fields.keys).isSubset(of: allowed) else { throw BackendError.unavailable("Fields do not match the workflow operation.") }
        return operation
    }

    func validate() throws {
        guard !operationID.isEmpty, operationID.utf8.count <= 80,
              operationID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:".contains($0)) }) else {
            throw BackendError.unavailable("Use a stable operationID of at most 80 letters, digits, dashes, underscores or colons.")
        }
        func valid(_ text: String?, limit: Int) -> Bool {
            guard let text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= limit
        }
        if let evidence {
            guard action == .reportResult, evidence.count <= 16,
                  evidence.allSatisfy({ !$0.source.isEmpty && $0.source.utf8.count <= 2_000 && !$0.observation.isEmpty && $0.observation.utf8.count <= 4_000 }) else {
                throw BackendError.unavailable("Evidence needs up to 16 source and observation pairs on a reportResult.")
            }
        }
        if action == .reportResult {
            guard valid(result, limit: Self.maximumReport), botID == nil, instructions == nil, expectedOutput == nil, role == nil else {
                throw BackendError.unavailable("reportResult needs a nonempty result of at most 24,000 bytes.")
            }
        } else {
            guard botID != nil, valid(instructions, limit: Self.maximumInstructions), valid(expectedOutput, limit: Self.maximumExpected), result == nil, verdict == nil else {
                throw BackendError.unavailable("A handoff needs a member botID, instructions and expectedOutput.")
            }
            guard action != .requestReview || role == nil || role == .reviewer else { throw BackendError.unavailable("Review requests must use the reviewer role.") }
            guard action == .requestReview || role != .reviewer else { throw BackendError.unavailable("Only a review request uses the reviewer role.") }
        }
    }

    /// The same operationID with a different payload is a different request.
    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Committed with the workflow in one ledger write, so a repeated tool call returns the same answer and creates nothing.
struct WorkflowOperationReceipt: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let taskID: String
    let action: WorkflowOperation.Action
    let fingerprint: String
    let createdTaskIDs: [String]
    let message: String

    func toolResult() throws -> String {
        try ComposioValue.object(["operationID": .string(id), "createdTaskIDs": .strings(createdTaskIDs), "message": .string(message)]).text()
    }
}

extension Workflow {
    static let maximumHandoffDepth = 3, maximumReviewRounds = 2, maximumOperations = 48

    /// Pure graph change; the caller commits the workflow (with its receipt) in one write. A thrown error leaves it as it was.
    mutating func apply(_ operation: WorkflowOperation, taskID: String, members: Set<UUID>) throws -> WorkflowOperationReceipt {
        var candidate = self
        let receipt = try candidate.applyValidated(operation, taskID: taskID, members: members)
        self = candidate
        return receipt
    }

    private mutating func applyValidated(_ operation: WorkflowOperation, taskID: String, members: Set<UUID>) throws -> WorkflowOperationReceipt {
        try operation.validate()
        guard state == .running || state == .paused, let index = tasks.firstIndex(where: { $0.id == taskID }),
              tasks[index].state == .running, members.contains(tasks[index].botID) else {
            throw BackendError.unavailable("Only the active owner of an unfinished task can change its workflow.")
        }
        let fingerprint = try operation.fingerprint
        if let receipt = operations?.first(where: { $0.id == operation.operationID }) {
            guard receipt.taskID == taskID, receipt.fingerprint == fingerprint else {
                throw BackendError.unavailable("This operationID was already used for a different request.")
            }
            return receipt
        }
        guard (operations?.count ?? 0) < operationLimit else { throw BackendError.unavailable("This workflow reached its operation limit.") }
        let before = Set(tasks.map(\.id)); let source = tasks[index]
        var message = "Result recorded. Finish this response; the task completes when your reply finishes."
        if operation.action == .reportResult {
            guard source.reportedResult == nil else { throw BackendError.unavailable("This task already reported its result. Reuse the original operationID to retrieve its receipt.") }
            guard (source.reviewTargetID != nil) == (operation.verdict != nil) else {
                throw BackendError.unavailable("Review tasks require accepted or needsRevision; other tasks must omit verdict.")
            }
            tasks[index].reportedResult = operation.result; tasks[index].reviewVerdict = operation.verdict
            tasks[index].evidence = operation.evidence
            if operation.verdict == .needsRevision {
                try addRevision(after: source)
                message += isTeam ? " Revision work is queued within the approved task." : " Revision work waits for the user's review."
            }
        } else {
            guard let assignee = operation.botID, members.contains(assignee) else { throw BackendError.unavailable("The assignee is not a current group member.") }
            guard source.reviewTargetID == nil,
                  !(operations ?? []).contains(where: { $0.taskID == taskID && $0.action != .reportResult }) else {
                throw BackendError.unavailable("Each task can request one handoff. Reviewers report a verdict instead.")
            }
            guard operation.action != .assign || source.botID == coordinatorID else { throw BackendError.unavailable("Only the coordinator can assign additional work.") }
            guard operation.action == .assign || assignee != source.botID else { throw BackendError.unavailable("Choose another member for help or review.") }
            let depth = (source.handoffDepth ?? 0) + 1
            guard depth <= depthLimit else { throw BackendError.unavailable("This workflow reached its handoff depth limit of \(depthLimit).") }
            var child = WorkflowTask(id: "task-" + UUID().uuidString, botID: assignee, instructions: operation.instructions ?? "",
                                     expectedOutput: operation.expectedOutput ?? "", dependencies: [source.id], role: operation.role == .coding ? .coding : .conversation)
            child.parentTaskID = source.id; child.handoffDepth = depth
            var additions = [child]
            if operation.action == .requestReview {
                let root = source.reviewRootID ?? source.id
                let round = (tasks.filter { $0.reviewRootID == root }.compactMap(\.reviewRound).max() ?? 0) + 1
                guard round <= reviewLimit else { throw BackendError.unavailable("This work reached its review-round allowance.") }
                additions[0].reviewTargetID = source.id; additions[0].reviewRootID = root; additions[0].reviewRound = round
            } else if operation.action == .requestHelp {
                var continuation = WorkflowTask(id: "continue-" + UUID().uuidString, botID: source.botID,
                    instructions: "Continue the original task using the helper's result. Original task: " + source.instructions.prefix(10_000),
                    expectedOutput: source.expectedOutput, dependencies: [source.id, child.id], role: source.role)
                continuation.parentTaskID = source.id; continuation.handoffDepth = source.handoffDepth
                continuation.reviewRootID = source.reviewRootID
                additions.append(continuation)
            }
            try insertFollowup(additions, after: source)
            if !isTeam { state = .paused; error = "New handoff tasks need your review. Work already sent may finish; approve the plan to send the new tasks." }
            message = isTeam ? "Handoff queued within the approved task. Finish your current response; SwarmHub will deliver it when available." : "Handoff saved for user review. Finish your current response with your findings. Do not wait for the new tasks in this turn."
        }
        try Self.validate(tasks, members: members, maximum: taskLimit)
        let receipt = WorkflowOperationReceipt(id: operation.operationID, taskID: taskID, action: operation.action, fingerprint: fingerprint,
                                               createdTaskIDs: tasks.filter { !before.contains($0.id) }.map(\.id), message: message)
        operations = (operations ?? []) + [receipt]
        return receipt
    }

    /// New work goes before the final synthesis, which then waits for it; work added after the synthesis itself gets a
    /// new synthesis by the coordinator.
    private mutating func insertFollowup(_ additions: [WorkflowTask], after source: WorkflowTask) throws {
        guard let terminal = additions.last, let final = tasks.last else { return }
        if source.id == final.id {
            var synthesis = WorkflowTask(id: "synthesis-" + UUID().uuidString, botID: coordinatorID,
                instructions: "Produce a consolidated answer including the new work and unresolved limitations. Original request: " + request,
                expectedOutput: "A consolidated answer", dependencies: [source.id, terminal.id])
            synthesis.parentTaskID = source.id; synthesis.handoffDepth = source.handoffDepth
            tasks.append(contentsOf: additions + [synthesis])
        } else {
            for index in tasks.indices where tasks[index].dependencies.contains(source.id) {
                guard tasks[index].state == .queued else { throw BackendError.unavailable("A dependent task has already started; the handoff cannot change its inputs.") }
                tasks[index].dependencies = tasks[index].dependencies.map { $0 == source.id ? terminal.id : $0 }
            }
            if !tasks[tasks.count - 1].dependencies.contains(terminal.id) { tasks[tasks.count - 1].dependencies.append(terminal.id) }
            guard tasks.last?.state == .queued else { throw BackendError.unavailable("The final synthesis has already started.") }
            tasks.insert(contentsOf: additions, at: tasks.count - 1)
        }
    }

    /// A first review that asks for changes adds one revision and a second review. A second rejection (or no room left)
    /// stops at the user: accept the review with its noted limitations, or cancel.
    private mutating func addRevision(after review: WorkflowTask) throws {
        guard let index = tasks.firstIndex(where: { $0.id == review.id }),
              let target = tasks.first(where: { $0.id == review.reviewTargetID }) else { throw BackendError.unavailable("The review target is unavailable.") }
        if !isTeam { state = .paused }
        guard (review.reviewRound ?? 1) < reviewLimit, tasks.count + 2 <= taskLimit else {
            tasks[index].reviewBlock = "The review reached its revision or task limit. Read the findings, then accept the review with its noted limitations or cancel this workflow."
            error = tasks[index].reviewBlock; return
        }
        var revision = WorkflowTask(id: "revision-" + UUID().uuidString, botID: target.botID,
            instructions: "Revise the original work using the review findings. Original task: " + target.instructions.prefix(10_000),
            expectedOutput: target.expectedOutput, dependencies: [target.id, review.id], role: target.role)
        revision.parentTaskID = target.id; revision.handoffDepth = target.handoffDepth
        revision.reviewRootID = review.reviewRootID ?? target.id
        var nextReview = WorkflowTask(id: "review-" + UUID().uuidString, botID: review.botID,
            instructions: review.instructions, expectedOutput: review.expectedOutput, dependencies: [revision.id])
        nextReview.parentTaskID = review.id; nextReview.handoffDepth = review.handoffDepth
        nextReview.reviewTargetID = revision.id; nextReview.reviewRound = (review.reviewRound ?? 1) + 1
        nextReview.reviewRootID = revision.reviewRootID
        try insertFollowup([revision, nextReview], after: review)
        if !isTeam { error = "The reviewer asked for changes. Review the revision and the second review before resuming." }
    }
}

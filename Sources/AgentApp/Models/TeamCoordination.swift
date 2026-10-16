import Foundation
import SwarmHubCoordination

/// Additive ledger data: older workflows retain their approval behaviour.
struct TeamCoordination: Codable, Equatable, Sendable {
    var policy: TeamPolicy
    var limits = TeamLimits()
    var reporting = TeamReporting()
    var originMessageID: UUID
    var activeSeconds: TimeInterval = 0
    var activeSince: Date?
    var resumeAfterRecovery = false
    var requiresEvidence = false
    var notificationEvents: Set<String> = []
    var steering: [String] = []
    var appReviews: [TeamAppReviewScope]?
    var actionDecisions: [TeamActionDecision]?
}

extension Workflow {
    var taskLimit: Int { coordination?.limits.tasks ?? Self.maximumTasks }
    var reviewLimit: Int { coordination?.limits.reviewRounds ?? Self.maximumReviewRounds }
    var depthLimit: Int { coordination?.limits.handoffDepth ?? Self.maximumHandoffDepth }
    var operationLimit: Int { coordination?.limits.operations ?? Self.maximumOperations }
    var parallelLimit: Int { coordination?.limits.parallelTasks ?? 1 }
    var isTeam: Bool { coordination != nil }
}

struct TeamAppReviewScope: Codable, Equatable, Sendable {
    var tool: String
    var account: String
    var reviewer: TeamIdentity
}

struct TeamActionDecision: Codable, Equatable, Sendable {
    var approvalID: UUID
    var fingerprint: String
    var policyVersion: Int
    var reviewer: TeamIdentity
    var approved: Bool
}

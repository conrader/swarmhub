import Foundation
import SwarmHubCoordination

/// Keep the ledger readable by pre-P6b3 builds: they already gate a finished, blocked review on user acceptance.
extension WorkflowTask {
    private static let acceptanceBlock = "The review is waiting for user acceptance. Read the findings, then accept the review with its noted limitations or cancel this workflow."

    private enum CodingKeys: String, CodingKey {
        case id, botID, instructions, expectedOutput, dependencies
        case role, state, threadID, result, resultArtifactID
        case error, reservation, chargedTokens, replyID, previousThreadIDs
        case parentTaskID, handoffDepth, reviewTargetID, reviewRootID, reviewRound
        case reportedResult, reviewVerdict, reviewBlock, completionConfirmed, reviewAcceptedByUser
        case delivery, evidence, verifiedByUser
        case awaitingUserAcceptance
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        botID = try values.decode(UUID.self, forKey: .botID)
        instructions = try values.decode(String.self, forKey: .instructions)
        expectedOutput = try values.decode(String.self, forKey: .expectedOutput)
        dependencies = try values.decode([String].self, forKey: .dependencies)
        role = try values.decode(ModelRole.self, forKey: .role)
        state = try values.decode(State.self, forKey: .state)
        threadID = try values.decode(UUID.self, forKey: .threadID)
        result = try values.decodeIfPresent(String.self, forKey: .result)
        resultArtifactID = try values.decodeIfPresent(UUID.self, forKey: .resultArtifactID)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        reservation = try values.decode(Int.self, forKey: .reservation)
        chargedTokens = try values.decodeIfPresent(Int.self, forKey: .chargedTokens)
        replyID = try values.decodeIfPresent(UUID.self, forKey: .replyID)
        previousThreadIDs = try values.decodeIfPresent([UUID].self, forKey: .previousThreadIDs)
        parentTaskID = try values.decodeIfPresent(String.self, forKey: .parentTaskID)
        handoffDepth = try values.decodeIfPresent(Int.self, forKey: .handoffDepth)
        reviewTargetID = try values.decodeIfPresent(String.self, forKey: .reviewTargetID)
        reviewRootID = try values.decodeIfPresent(String.self, forKey: .reviewRootID)
        reviewRound = try values.decodeIfPresent(Int.self, forKey: .reviewRound)
        reportedResult = try values.decodeIfPresent(String.self, forKey: .reportedResult)
        reviewVerdict = try values.decodeIfPresent(WorkflowOperation.Verdict.self, forKey: .reviewVerdict)
        reviewBlock = try values.decodeIfPresent(String.self, forKey: .reviewBlock)
        completionConfirmed = try values.decodeIfPresent(Bool.self, forKey: .completionConfirmed)
        reviewAcceptedByUser = try values.decodeIfPresent(Bool.self, forKey: .reviewAcceptedByUser)
        delivery = try values.decodeIfPresent(TeamDelivery.self, forKey: .delivery)
        evidence = try values.decodeIfPresent([TeamEvidence].self, forKey: .evidence)
        verifiedByUser = try values.decodeIfPresent(Bool.self, forKey: .verifiedByUser)
        // Also accepts the original P6b3 state string, which State still recognizes.
        if try values.decodeIfPresent(Bool.self, forKey: .awaitingUserAcceptance) == true {
            state = .awaitingUserAcceptance
            if reviewBlock == Self.acceptanceBlock { reviewBlock = nil }
            if error == Self.acceptanceBlock { error = nil }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let waiting = state == .awaitingUserAcceptance
        try values.encode(id, forKey: .id)
        try values.encode(botID, forKey: .botID)
        try values.encode(instructions, forKey: .instructions)
        try values.encode(expectedOutput, forKey: .expectedOutput)
        try values.encode(dependencies, forKey: .dependencies)
        try values.encode(role, forKey: .role)
        try values.encode(waiting ? State.blocked : state, forKey: .state)
        try values.encode(threadID, forKey: .threadID)
        try values.encodeIfPresent(result, forKey: .result)
        try values.encodeIfPresent(resultArtifactID, forKey: .resultArtifactID)
        try values.encodeIfPresent(waiting ? (error ?? Self.acceptanceBlock) : error, forKey: .error)
        try values.encode(reservation, forKey: .reservation)
        try values.encodeIfPresent(chargedTokens, forKey: .chargedTokens)
        try values.encodeIfPresent(replyID, forKey: .replyID)
        try values.encodeIfPresent(previousThreadIDs, forKey: .previousThreadIDs)
        try values.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
        try values.encodeIfPresent(handoffDepth, forKey: .handoffDepth)
        try values.encodeIfPresent(reviewTargetID, forKey: .reviewTargetID)
        try values.encodeIfPresent(reviewRootID, forKey: .reviewRootID)
        try values.encodeIfPresent(reviewRound, forKey: .reviewRound)
        try values.encodeIfPresent(reportedResult, forKey: .reportedResult)
        try values.encodeIfPresent(reviewVerdict, forKey: .reviewVerdict)
        try values.encodeIfPresent(waiting ? (reviewBlock ?? Self.acceptanceBlock) : reviewBlock, forKey: .reviewBlock)
        try values.encodeIfPresent(waiting ? true : completionConfirmed, forKey: .completionConfirmed)
        try values.encodeIfPresent(reviewAcceptedByUser, forKey: .reviewAcceptedByUser)
        try values.encodeIfPresent(delivery, forKey: .delivery)
        try values.encodeIfPresent(evidence, forKey: .evidence)
        try values.encodeIfPresent(verifiedByUser, forKey: .verifiedByUser)
        if waiting { try values.encode(true, forKey: .awaitingUserAcceptance) }
    }
}

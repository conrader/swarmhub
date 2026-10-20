import Testing
@testable import SwarmHubCoordination

@Test(arguments: [Set(["assign", "requestReview"]), Set(["assign"]), Set<String>()])
func reviewsWithoutReportingGoToTheUser(actions: Set<String>) {
    let policy = TeamReviewPolicy(actions: actions)
    #expect(!policy.allowsReporting)
    #expect(policy.instructions.contains("The result goes to the user for acceptance"))
    #expect(!policy.instructions.contains("verdict"))
    #expect(policy.completion(hasStructuredVerdict: false) == .awaitingUserAcceptance)
}

@Test func reportingStillRequiresStructuredVerdicts() {
    let cases: [Set<String>?] = [nil, ["reportResult"], ["assign", "reportResult", "requestReview"]]
    for actions in cases {
        let policy = TeamReviewPolicy(actions: actions)
        #expect(policy.instructions == "reportResult with a verdict is required")
        #expect(policy.completion(hasStructuredVerdict: false) == .missingVerdict)
        #expect(policy.completion(hasStructuredVerdict: true) == .reported)
    }
    // A verdict already recorded through an authorized operation remains a structured result.
    #expect(TeamReviewPolicy(actions: []).completion(hasStructuredVerdict: true) == .reported)
}

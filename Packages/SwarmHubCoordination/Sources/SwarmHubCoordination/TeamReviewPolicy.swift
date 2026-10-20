/// Review wording and completion routing shared by the Mac and iOS coordination layer.
/// Only structured operations supply verdicts; reply text never grants acceptance.
public struct TeamReviewPolicy: Sendable {
    public enum Completion: Equatable, Sendable {
        case reported, missingVerdict, awaitingUserAcceptance
    }

    public let allowsReporting: Bool

    /// A workflow without a team policy retains the compiled reporting behavior.
    public init(actions: Set<String>?) {
        allowsReporting = actions?.contains("reportResult") ?? true
    }

    public var instructions: String {
        allowsReporting ? "reportResult with a verdict is required"
            : "Return your findings in a normal reply. The result goes to the user for acceptance; the workflow waits for that acceptance."
    }

    public func completion(hasStructuredVerdict: Bool) -> Completion {
        if hasStructuredVerdict { return .reported }
        return allowsReporting ? .missingVerdict : .awaitingUserAcceptance
    }
}

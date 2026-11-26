import Foundation

/// Saved with the bot. A queued step has never been submitted. A running step may
/// already have reached the agent, even when the transcript has no reply yet.
struct ChatGoal: Codable, Equatable {
    enum State: String, Codable {
        case queued, running, waiting, completed, stopped

        var active: Bool { self != .completed && self != .stopped }
    }

    struct Report: Codable {
        enum Outcome: String, Codable { case progress, complete, blocked, noProgress = "no_progress", failed }
        let iteration: UUID
        let outcome: Outcome
        let evidence: String

        static func read(_ reply: String, for attempt: UUID) -> (report: Self, prose: String)? {
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = text.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            guard let report = try? JSONDecoder().decode(Self.self, from: Data(text[start...].utf8)),
                  report.iteration == attempt, !report.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (report, String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct Destination: Codable, Equatable {
        let serverID: String
        let connection: HerdrServer.Kind
        let address: String
        let sshHost: String
        let sshUser: String
        let agent: String
        let sessionID: String
    }
    let id: UUID
    var initialAttachments: [ChatAttachment]?
    var objective: String
    let destination: Destination
    var state = State.queued
    struct SpendReading: Codable, Equatable {
        let core: String
        let agent: HerdrClient.AgentRef
        let tokens: Int64
        let usd: Double

        // OpenCode accumulates dollars as a Double. Discard sub-picodollar noise
        // before subtracting two readings so a cent-exact cap stops on its boundary.
        var reportedDollars: Decimal? {
            guard usd.isFinite, usd >= 0, var raw = Decimal(string: String(usd)) else { return nil }
            var rounded = Decimal()
            NSDecimalRound(&rounded, &raw, 12, .plain)
            return rounded
        }
    }

    var budgetUSD: Double?
    /// Absent on legacy session ceilings, including goals restored from earlier versions.
    struct StepSpending: Codable, Equatable {
        var chargedUSD: Decimal = 0
        var pending: SpendReading?
        var attempt: UUID?
    }
    var stepSpending: StepSpending?
    var lastSpend: SpendReading?
    var spendProgress: String? {
        guard let budgetUSD else { return nil }
        let ceiling = budgetUSD.formatted(.currency(code: "USD"))
        if let stepSpending {
            let charged = stepSpending.chargedUSD.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
            return "Goal spend: \(charged) / \(ceiling)" + (stepSpending.pending == nil ? "" : " · step cost pending")
        }
        if let lastSpend { return "Session spend: \(lastSpend.usd.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) / \(ceiling)" }
        return "Session budget: \(ceiling) · checked before each step"
    }

    mutating func stopAtGoalSpendingLimit() -> Bool {
        guard let charged = stepSpending?.chargedUSD, let budgetUSD,
              let limit = Decimal(string: String(budgetUSD)), charged >= limit else { return false }
        stop()
        detail = "This goal reached its spending limit."
        return true
    }

    mutating func permitsNextStep(spend: SpendReading?) -> Bool {
        guard let budgetUSD else { return true }
        guard let spend, spend.usd.isFinite, spend.usd >= 0, spend.tokens >= 0 else {
            wait("This goal needs an OpenCode session with reported USD usage. Resume after usage becomes available.")
            return false
        }
        if let previous = lastSpend {
            guard previous.core == spend.core, previous.agent == spend.agent, spend.tokens >= previous.tokens, spend.usd >= previous.usd else {
                wait("The priced session changed. Start a new goal to use its budget.")
                return false
            }
        }
        if stepSpending != nil {
            if stepSpending?.pending != nil, !recordStepCost(spend) {
                wait("Waiting for the cost of the preceding goal step. Resume when updated usage is available.")
                return false
            }
            if stopAtGoalSpendingLimit() { return false }
            stepSpending?.pending = spend
            lastSpend = spend
            return true
        }
        if spend.usd >= budgetUSD {
            lastSpend = spend
            stop()
            detail = "The session reached its spending limit."
            return false
        }
        if let previous = lastSpend, spend.tokens <= previous.tokens {
            wait("Waiting for updated token and cost totals from the last step. Resume when usage is available.")
            return false
        }
        lastSpend = spend
        return true
    }

    /// A provider reports a cumulative meter. Charge the increase across this step once.
    /// A pending reading survives a crash and prevents a further step until it is accounted for.
    @discardableResult mutating func recordStepCost(_ end: SpendReading?) -> Bool {
        guard var spending = stepSpending, let start = spending.pending, let end,
              start.core == end.core, start.agent == end.agent, end.tokens > start.tokens,
              end.usd.isFinite, end.usd >= start.usd,
              let endUSD = end.reportedDollars, let startUSD = start.reportedDollars
        else { return false }
        spending.chargedUSD += endUSD - startUSD
        spending.pending = nil
        spending.attempt = nil
        stepSpending = spending
        lastSpend = end
        return true
    }

    var stepLimit: Int?
    var stepProgress: String? { stepLimit.map { "Steps: \(iteration) of \($0)" } }
    var iteration = 0
    var attempt: UUID?
    var detail = ""
    private var stalls = 0
    private var progressEvidence: [String] = []

    init(objective: String, destination: Destination, stepLimit: Int? = nil) {
        id = UUID()
        self.objective = objective
        self.stepLimit = stepLimit
        self.destination = destination
    }

    /// Check immediately before each automatic dispatch, including steps restored from disk.
    mutating func stopAtStepLimit() -> Bool {
        guard let stepLimit, iteration >= stepLimit else { return false }
        state = .stopped
        attempt = nil
        detail = "Step limit reached." + (detail.isEmpty ? "" : " " + detail)
        return true
    }

    mutating func begin() -> UUID {
        let token = UUID()
        attempt = token
        if stepSpending?.pending != nil { stepSpending?.attempt = token }
        iteration += 1
        state = .running
        return token
    }

    func request(for token: UUID) -> String {
        let instructions = """
        Work on one step toward this goal: \(objective)
        Use the normal workspace approval process. If input or approval is needed, wait for the person.
        End your reply with one JSON line for this step. Set outcome to progress, complete, blocked, no_progress, or failed.
        For progress name the new result. For complete give evidence that the entire objective was met. Otherwise explain what is needed.
        {"iteration":"\(token.uuidString)","outcome":"...","evidence":"..."}
        """
        guard !detail.isEmpty else { return instructions }
        // An objective that fit on the first step must still fit on its next step.
        let lead = "\nLast result: "
        let room = HerdrClient.messageBytes - instructions.utf8.count - lead.utf8.count
        return room > 0 ? instructions + lead + HerdrClient.plain(detail, bytes: room) : instructions
    }

    mutating func finish(_ report: Report) {
        guard state == .running, attempt == report.iteration else { return }
        attempt = nil
        detail = String(report.evidence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        switch report.outcome {
        case .complete: state = .completed
        case .blocked: state = .waiting
        case .failed, .noProgress:
            stalls += 1
            state = .queued
        case .progress:
            let key = detail.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if progressEvidence.contains(key) { stalls += 1 }
            else {
                progressEvidence.append(key)
                if progressEvidence.count > 32 { progressEvidence.removeFirst() }
                stalls = 0
            }
            state = .queued
        }
        if state == .queued, stopAtStepLimit() { return }
        if state == .queued, stalls >= 2 {
            wait("Two steps produced no new progress. " + detail)
        }
    }

    mutating func wait(_ reason: String) {
        attempt = nil
        state = .waiting
        detail = reason
    }

    mutating func resume() {
        guard state == .waiting else { return }
        state = .queued
        stalls = 0
        progressEvidence.removeAll()
    }

    mutating func stop() {
        state = .stopped
        attempt = nil
        detail = "Stopped by you."
    }
}

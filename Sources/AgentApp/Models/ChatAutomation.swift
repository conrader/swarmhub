import Foundation

/// P45 2–4: what SwarmHub itself runs in one chat: a standing goal and a loop. Kept in store.json (keyed by the chat's id)
/// so they survive a restart; the driver lives in `AppStore+Goals.swift` / `AppStore+Loops.swift`. P46: the heartbeat is a
/// Hermes routine per bot now (`AppStore+BotHeartbeat.swift`); a P45 `heartbeat` key in an older store.json is ignored.
struct ChatAutomation: Codable, Equatable, Sendable {
    var goal: GoalRun?; var loop: LoopRun?
    var isEmpty: Bool { goal == nil && loop == nil }
}

/// Why SwarmHub started a turn the user didn't type (shown as "Woken by: goal").
enum AutomationKind: String, Codable, Sendable { case goal, loop, heartbeat }

enum AutomationKey {
    /// On the user row SwarmHub sent: the kind ("goal", "loop", "heartbeat"); its bubble shows the short text in `display`.
    static let woken = "automation.woken", display = "automation.display"
    /// On a card row: "goalDone", "goalBlocked", "goalEnded"; and the text the card shows below its title.
    static let card = "automation.card", detail = "automation.detail"
    /// P46: a delivered heartbeat (or routine) row whose reply was exactly `[SILENT]`: both rows are hidden ("1").
    static let silent = "automation.silent"
    /// P49: on the user row of a new bot's orientation turn ("1"); its bubble shows "Orientation" (`display`).
    static let orientation = "automation.orientation"
}

struct GoalRun: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, paused, done, blocked, ended }
    var text: String; var subgoals: [String] = []
    var state: State = .running
    /// Turns sent so far (the first is round 1) and the budget.
    var round = 0; var maxRounds: Int
    var startedAt: Date; var maxDuration: TimeInterval
    /// A round was sent and its reply has not ended yet.
    var awaitingReply = false
    /// Paused because the connection went offline (resumes by itself when it is back).
    var pausedOffline = false
    var lastSummary: String?; var need: String?; var endReason: String?
    /// Rounds spent asking for evidence after a `done` block that had none (optional: goals saved before it existed).
    var evidenceRounds: Int?
    /// Explicit /goal --coding opts into commit/test + report evidence. Older/general goals accept chat deliverables.
    var codingEvidence: Bool?

    func accepts(_ evidence: GoalEvidence, reply: String) -> Bool {
        if codingEvidence == true { return evidence.isSufficient }
        return evidence.deliverable != nil || !SwarmhubBlock.visibleText(reply).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isActive: Bool { state == .running || state == .paused }
    var deadline: Date { startedAt.addingTimeInterval(maxDuration) }
    func budgetSpent(at now: Date) -> Bool { round >= maxRounds || now >= deadline }

    /// "Goal: ship the release notes · round 3/20".
    var chipTitle: String { "Goal: \(text)" }
    var progress: String { "round \(round)/\(maxRounds)" }
}

/// P45 2: the protocol around a goal: the first turn, each continuation, and the block that ends it.
enum GoalProtocol {
    static let defaultRounds = 20, defaultHours = 2.0
    static let roundsKey = "goalMaxRounds", hoursKey = "goalMaxHours"

    static func firstTurn(_ goal: GoalRun) -> String {
        if goal.codingEvidence != true {
            return """
            [SwarmHub goal] Work toward this goal across turns until it is fully achieved: \(goal.text)\(criteria(goal))
            Deliver the requested result in chat or name the actual deliverable in evidence.deliverable. Respect all acceptance criteria and constraints.
            When complete, end with:
            ```swarmhub
            {"op":"goal","status":"done","summary":"<what was delivered>","evidence":{"deliverable":"<actual result or source reference>"}}
            ```
            If blocked, end with a swarmhub goal block with status "blocked" and "need". Never invent evidence.
            """
        }
        return """
        [SwarmHub goal] Work toward this goal across turns until it is fully achieved: \(goal.text)\(criteria(goal))

        SwarmHub sends "Continue toward the goal" after each of your replies until you end it. When the goal is fully \
        achieved, end your reply with:
        ```swarmhub
        {"op":"goal","status":"done","summary":"<one or two sentences>","evidence":{"commit":"<commit id you made>","tests":"passed","report":"<path of the fresh report you wrote>"}}
        ```
        Done is accepted only with evidence you actually produced: a commit id or "tests":"passed" (a test run you made), \
        plus the fresh report path. Leave out what you did not do; never invent any of them. SwarmHub records them as \
        claimed by you, not verified. Without evidence, report blocked instead.
        If you are blocked and need something from Konrad, end your reply with:
        ```swarmhub
        {"op":"goal","status":"blocked","need":"<what you need>"}
        ```
        """
    }

    static func continuation(_ goal: GoalRun) -> String {
        "Continue toward the goal: \(goal.text)\(criteria(goal))\n(Round \(goal.round + 1) of \(goal.maxRounds). End with the swarmhub goal block when done or blocked.)"
    }

    private static func criteria(_ goal: GoalRun) -> String {
        goal.subgoals.isEmpty ? "" : "\nAlso required:\n" + goal.subgoals.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    enum Report: Equatable { case done(summary: String, evidence: GoalEvidence), blocked(need: String) }

    /// How many times a `done` without evidence is sent back before the goal is blocked for you.
    static let maxEvidenceRounds = 2

    /// The round that answers a `done` block without accepted evidence.
    static func evidenceRequest(_ goal: GoalRun, evidence: GoalEvidence) -> String {
        if goal.codingEvidence != true {
            return "Deliver the requested result for \(goal.text) in chat, or identify its actual reference in evidence.deliverable, then send the done block. If blocked, report blocked."
        }
        return "Your done block for the goal \"\(goal.text)\" has no accepted evidence (missing: \(evidence.missing.joined(separator: "; "))). " +
        "Either end your reply with the done block again, adding \"evidence\": {\"tests\": \"passed\", " +
        "\"report\": \"<fresh report path>\"} for work you actually did (or replace tests with a commit id), or report blocked with what is missing. " +
        "Never invent a commit, a test run or a report."
    }

    /// The last goal block in a reply (fenced ```swarmhub, `op` "goal"); nil when there is none.
    static func report(in text: String) -> Report? {
        for fence in SwarmhubBlock.fences(in: text).reversed() {
            guard let data = fence.body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for object in objects.reversed() where object["op"] as? String == "goal" {
                switch object["status"] as? String {
                case "done": return .done(summary: (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                          evidence: GoalEvidence.parse(object["evidence"]))
                case "blocked": return .blocked(need: (object["need"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                default: continue
                }
            }
        }
        return nil
    }
}

/// What a `done` goal block claims as evidence (P01/P04 gap). SwarmHub cannot read the bot's box, so it records these as
/// claimed by the bot, not verified. Explicit coding goals require commit/tests + report; other goals accept their deliverable.
struct GoalEvidence: Equatable, Codable, Sendable {
    var commit: String?; var testsPassed = false; var report: String?; var deliverable: String? = nil

    var isSufficient: Bool { (commit != nil || testsPassed) && report != nil }
    var claimed: [String] {
        var items: [String] = []
        if let commit { items.append("commit \(commit)") }
        if testsPassed { items.append("tests passed") }
        if let report { items.append("report \(report)") }
        if let deliverable { items.append("deliverable \(deliverable)") }
        return items
    }
    var missing: [String] {
        var items: [String] = []
        if commit == nil && !testsPassed { items.append("a commit id or a test pass") }
        if report == nil { items.append("the fresh report path") }
        return items
    }
    /// "Claimed by the bot, not verified by SwarmHub: commit abc1234; report /x.\nMissing: …" (shown on the goal card).
    var summary: String {
        var lines = ["Claimed by the bot, not verified by SwarmHub: " + (claimed.isEmpty ? "nothing" : claimed.joined(separator: "; ")) + "."]
        if !missing.isEmpty { lines.append("Missing: " + missing.joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }

    /// The `evidence` object of a goal block. A commit must look like one (7–64 hex digits), so the protocol's
    /// placeholders never count; `tests` is "passed" or `true`; `report` is any nonempty path.
    static func parse(_ value: Any?) -> GoalEvidence {
        guard let object = value as? [String: Any] else { return GoalEvidence() }
        func text(_ key: String) -> String? {
            let value = (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let commit = text("commit").flatMap { $0.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) == nil ? nil : $0 }
        let tests = (object["tests"] as? String)?.lowercased() == "passed" || (object["tests"] as? Bool) == true
        let report = text("report").flatMap { value -> String? in
            guard !value.contains("<"), !value.contains(">"), !value.contains("\n"),
                  !["none", "unknown", "n/a", "pending"].contains(value.lowercased()) else { return nil }
            return value
        }
        let deliverable = text("deliverable").flatMap { value -> String? in
            guard !value.contains("<"), !value.contains(">"),
                  !["none", "unknown", "n/a", "pending"].contains(value.lowercased()) else { return nil }
            return value
        }
        return GoalEvidence(commit: commit, testsPassed: tests, report: report, deliverable: deliverable)
    }
}

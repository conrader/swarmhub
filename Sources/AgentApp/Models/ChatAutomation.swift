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
        """
        [SwarmHub goal] Work toward this goal across turns until it is fully achieved: \(goal.text)\(criteria(goal))

        SwarmHub sends "Continue toward the goal" after each of your replies until you end it. When the goal is fully \
        achieved, end your reply with:
        ```swarmhub
        {"op":"goal","status":"done","summary":"<one or two sentences>"}
        ```
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

    enum Report: Equatable { case done(summary: String), blocked(need: String) }

    /// The last goal block in a reply (fenced ```swarmhub, `op` "goal"); nil when there is none.
    static func report(in text: String) -> Report? {
        for fence in SwarmhubBlock.fences(in: text).reversed() {
            guard let data = fence.body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (json as? [[String: Any]]) ?? [(json as? [String: Any])].compactMap { $0 }
            for object in objects.reversed() where object["op"] as? String == "goal" {
                switch object["status"] as? String {
                case "done": return .done(summary: (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                case "blocked": return .blocked(need: (object["need"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                default: continue
                }
            }
        }
        return nil
    }
}

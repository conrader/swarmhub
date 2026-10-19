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
    /// `/goal --coding` (true) opts into commit/test + report evidence; `/goal --general` (false) opts out. A plain
    /// `/goal` (nil) is held to that evidence when its text asks for code changes (cross-review finding 8).
    var codingEvidence: Bool?
    var requiresCodingEvidence: Bool { codingEvidence ?? GoalProtocol.looksLikeCoding(text) }

    func accepts(_ evidence: GoalEvidence, reply: String) -> Bool {
        if requiresCodingEvidence { return evidence.isSufficient }
        return evidence.deliverable != nil || !SwarmhubBlock.visibleText(reply).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The done card's second line: the claimed coding evidence, or the general wording, marked unverified when the
    /// text looked like coding work but the goal was started `--general`.
    func doneDetail(_ evidence: GoalEvidence) -> String {
        if requiresCodingEvidence { return evidence.summary }
        let general = "Deliverable provided in chat or at the supplied reference; claimed complete by the bot."
        return GoalProtocol.looksLikeCoding(text) ? "Unverified (general goal): " + general : general
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
        if !goal.requiresCodingEvidence {
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

    /// Cross-review issue B: a plain goal is classified by the requested action, not by nouns alone. Asking to change
    /// or build something that names a code object is coding; explaining, describing or reviewing it is general even
    /// when the same nouns appear. The first recognised verb decides; words after "about"/"regarding" are the topic
    /// of prose ("a blog post about Python"), not the object of the work.
    static let explainVerbs: Set<String> = ["explain", "describe", "summarize", "summarise", "document", "outline", "review",
                                            "compare", "analyze", "analyse", "assess", "evaluate", "research", "list", "tell",
                                            "teach", "walk", "clarify", "read", "recap", "what", "why", "how", "which", "who",
                                            "when", "where", "is", "are", "does"]
    /// Actions that change or build. Alone they are not coding ("build a presentation", "write the changelog"): a
    /// code noun must follow them.
    static let changeVerbs: Set<String> = ["add", "fix", "write", "upgrade", "update", "bump", "build", "create", "remove",
                                           "delete", "rename", "port", "convert", "optimize", "optimise", "replace", "integrate",
                                           "set", "configure", "make", "run", "ship", "release", "deploy", "open", "land", "revert",
                                           "install", "pin", "drop", "enable", "disable", "improve", "finish", "clean", "split",
                                           "move", "change", "modify", "stop", "prevent", "handle", "support", "wire", "extract",
                                           "generate", "migrate", "merge", "test", "address"]
    /// Actions that only make sense for code: coding whether or not an object is named.
    static let codingOnlyVerbs: Set<String> = ["implement", "refactor", "rewrite", "debug", "patch", "compile", "lint", "typecheck",
                                               "commit", "rebase", "backport", "scaffold", "deduplicate"]
    /// Objects of coding work. Deliberately no plain product words: "the changelog", "the meeting", "a presentation".
    static let codeNouns: Set<String> = ["bug", "bugs", "code", "codebase", "repo", "repository", "commit", "commits", "branch", "pr",
                                         "prs", "test", "tests", "build", "ci", "lint", "linter", "migration", "migrations", "script",
                                         "scripts", "function", "functions", "endpoint", "endpoints", "api", "apis", "typecheck",
                                         "react", "python", "javascript", "typescript", "swift", "swiftui", "rust", "java", "kotlin",
                                         "node", "npm", "pip", "docker", "dockerfile", "kubernetes", "scraper", "crawler", "parser",
                                         "compiler", "library", "package", "dependency", "dependencies", "module", "class", "method",
                                         "schema", "database", "sql", "query", "route", "handler", "middleware", "component", "cli",
                                         "sdk", "readme", "makefile", "config", "yaml", "json", "regex", "crash", "exception", "failure",
                                         "traceback", "segfault", "xcode", "html", "css", "frontend", "backend", "server",
                                         "deployment", "pipeline", "unittest", "pytest", "jest", "cargo", "gradle", "webpack",
                                         "eslint", "mypy", "ruff"]
    static let codePhrases = ["pull request", "stack trace", "unit test", "merge conflict", "type error", "compile error"]

    /// Codex review of fixes7: a clear coding request anywhere in the text wins over earlier descriptive verbs ("The
    /// tests are failing; fix the bug"). An imperative is a change or coding-only verb at the start of a clause: the
    /// start of the text, after ";", "!", "?", a newline or a sentence-ending ".", or after ",", "so" or "please"
    /// outside a question ("How do I add tests, then fix the build?" stays a question). "then", "now", "just", "also",
    /// "and" and "can/could/would/will you" may stand before it. A change verb is coding when a code noun follows it in
    /// its clause, or when its object is a pronoun ("fix it") and the text names code. After a descriptive request,
    /// "and"/"then" opens another imperative, including polite "can you explain…" requests. How/why questions keep
    /// their existing interpretation. Otherwise the fixes7 rule decides.
    static let clauseWords: Set<String> = ["so", "please"]
    static let leadIns: Set<String> = ["then", "now", "just", "also", "and"]
    static let askingVerbs: Set<String> = ["can", "could", "would", "will"]
    static let questionStarters: Set<String> = ["how", "what", "why", "which", "who", "when", "where", "is", "are", "does",
                                                "do", "can", "could", "should"]
    static let pronouns: Set<String> = ["it", "them", "this", "that", "these", "those"]

    static func looksLikeCoding(_ text: String) -> Bool {
        requestsCodeInAClause(text) || firstVerbRequestsCode(text)
    }

    static func requestsCodeInAClause(_ text: String) -> Bool {
        let parts = sentenceWords(text)
        var topic = parts.flatMap { $0 }.filter { $0 != "," }
        if let about = topic.firstIndex(where: { $0 == "about" || $0 == "regarding" }) {
            topic = Array(topic[..<about])
        }
        let mentionsCode = namesCode(topic)
        for words in parts {
            let question = questionStarters.contains(words[0])
            var clauseStart = true
            var explains = false
            var embedded = false
            var index = 0
            while index < words.count {
                let word = words[index]
                index += 1
                // "Explain how to build and test" keeps both verbs inside the
                // explanation. A new sentence still starts a fresh imperative.
                if explains && questionStarters.contains(word) { embedded = true }
                if explains && !embedded && (word == "and" || word == "then") {
                    clauseStart = true
                    continue
                }
                if clauseStart && explainVerbs.contains(word) && (!question || askingVerbs.contains(words[0])) {
                    explains = true
                }
                if word == "," || clauseWords.contains(word) {
                    clauseStart = clauseStart || (!question && !embedded)
                    continue
                }
                if clauseStart && leadIns.contains(word) { continue }
                if clauseStart && askingVerbs.contains(word) && index < words.count && words[index] == "you" {
                    index += 1
                    continue
                }
                if clauseStart && codingOnlyVerbs.contains(word) { return true }
                if clauseStart && changeVerbs.contains(word) {
                    let objects = Array(words[index...].prefix(while: { $0 != "," && !clauseWords.contains($0) && $0 != "about" && $0 != "regarding" }))
                    if namesCode(objects) { return true }
                    if let first = objects.first, pronouns.contains(first), mentionsCode { return true }
                }
                clauseStart = false
            }
        }
        return false
    }

    /// Fixes7 rule: the first recognised verb decides; without one a code noun decides.
    static func firstVerbRequestsCode(_ text: String) -> Bool {
        var words = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        if let topic = words.firstIndex(where: { $0 == "about" || $0 == "regarding" }) {
            words = Array(words[..<topic])
        }
        var objects = words[...]
        if let action = words.firstIndex(where: { explainVerbs.contains($0) || changeVerbs.contains($0) || codingOnlyVerbs.contains($0) }) {
            let verb = words[action]
            if explainVerbs.contains(verb) { return false }
            if codingOnlyVerbs.contains(verb) { return true }
            objects = words[(action + 1)...]
        }
        return namesCode(Array(objects))
    }

    static func namesCode(_ words: [String]) -> Bool {
        let scope = words.joined(separator: " ")
        return words.contains { codeNouns.contains($0) } || codePhrases.contains { scope.contains($0) }
    }

    /// Lowercased words per sentence (split at ";", "!", "?", a newline, or a "." followed by a space or the end);
    /// a comma stays in as the token ",".
    static func sentenceWords(_ text: String) -> [[String]] {
        let characters = Array(text.lowercased())
        var parts: [[String]] = [[]]
        var word = ""
        for (offset, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                parts[parts.count - 1].append(word)
                word = ""
            }
            let endsSentence = character == ";" || character == "!" || character == "?" || character.isNewline
                || (character == "." && (offset + 1 == characters.count || characters[offset + 1].isWhitespace))
            if endsSentence {
                if !parts[parts.count - 1].isEmpty { parts.append([]) }
            } else if character == "," {
                parts[parts.count - 1].append(",")
            }
        }
        if !word.isEmpty { parts[parts.count - 1].append(word) }
        return parts.filter { !$0.isEmpty }
    }

    /// The round that answers a `done` block without accepted evidence.
    static func evidenceRequest(_ goal: GoalRun, evidence: GoalEvidence) -> String {
        if !goal.requiresCodingEvidence {
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

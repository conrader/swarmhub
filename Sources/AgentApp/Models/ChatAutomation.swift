import Foundation

/// P45 2–4: what SwarmHub itself runs in one chat: a standing goal and a loop. Kept in store.json (keyed by the chat's id)
/// so they survive a restart; the driver lives in `AppStore+Goals.swift` / `AppStore+Loops.swift`. P46: the heartbeat is a
/// Hermes routine per bot now (`AppStore+BotHeartbeat.swift`); a P45 `heartbeat` key in an older store.json is ignored.
struct ChatAutomation: Codable, Equatable, Sendable {
    var goal: GoalRun?; var loop: LoopRun?
    /// The loop or goal SwarmHub handed to the box when it quit, until it takes it back (kept after a stop, so the box's
    /// routine is still deleted).
    var boxHandoff: BoxHandoff?
    var isEmpty: Bool { goal == nil && loop == nil && boxHandoff == nil }
}

/// A loop or goal running on the bot's box while SwarmHub is closed: the Hermes routine `swarmhub-loop|goal-<chat id>`
/// (`AppStore+AutomationHandoff.swift`). `jobID` is nil when the quit ended before the box answered; the name finds it.
struct BoxHandoff: Codable, Equatable, Sendable {
    var kind: AutomationKind
    var jobName: String
    var jobID: String?
    var handedAt: Date
    /// Taking it back waits while a box round is still in flight (since this time), and the last reason it could not.
    var waitingSince: Date? = nil
    /// What the wait is for (`busy`, `running`, `behind`): a new reason starts the clock again.
    var waitingFor: String? = nil
    var lastError: String? = nil
    /// The user took it over with rounds the chat lacks (`HandoffCopy.roundsMissing`): the box's count is used.
    var takeOver: Bool? = nil
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

    /// Shared by the local start notice and /goal status, including restored goals with no explicit override.
    var evidenceStatus: String {
        let mode = requiresCodingEvidence ? "coding" : "general"
        let source = codingEvidence == nil ? "auto" : "explicit"
        let requirement = requiresCodingEvidence ? "commit or test pass + report required" : "chat deliverable; coding evidence not required"
        return "Evidence: \(mode) (\(source); \(requirement)).\nTo override, /goal clear, then /goal --coding <text> or /goal --general <text>."
    }

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

    /// The round the box sends every 15 minutes while SwarmHub is closed (`AppStore+AutomationHandoff.swift`).
    static func boxContinuation(_ goal: GoalRun) -> String {
        "Continue toward the goal: \(goal.text)\(criteria(goal))\n(SwarmHub is closed; this comes every 15 minutes. End with the swarmhub goal block when done or blocked.)"
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
    static let leadIns: Set<String> = ["then", "now", "just", "also", "and", "plus"]
    static let askingVerbs: Set<String> = ["can", "could", "would", "will"]
    static let questionStarters: Set<String> = ["how", "what", "why", "which", "who", "when", "where", "is", "are", "does",
                                                "do", "can", "could", "should"]
    static let pronouns: Set<String> = ["it", "them", "this", "that", "these", "those"]
    /// Xrev2 finding 1: inside an explained "why/what/where …" clause, "and"/"then" reopens an imperative ("Explain why
    /// the parser crashes and then fix it"). Only "how to V1 and V2 X" shares the infinitive to the end of the clause.
    /// A change verb after one of these words is the explained clause's own verb ("why we add tests and remove
    /// packages"), so a bare "and" then coordinates with it instead of opening an imperative; "then" still does. Once
    /// "how to V" has its object, a comma or "then" ends the infinitive ("how to build the parser, and fix the crash").
    /// A comma also ends a finite explanatory clause, even with coordinated verbs. "plus" follows the same rule as
    /// "and"; "also" can lead a command after a boundary but alone does not end an explanatory clause.
    /// "we also add" still supplies the clause's own verb; neither "also" nor "plus" is an infinitive's object.
    /// Fixes14: a comma right after the explanation's own verb that opens a series of two or more verbs ("why we
    /// install, configure and run the server", "build, test, and then deploy") keeps the series inside the
    /// explanation; the series ends at the verb after its first conjunction. A comma after an object still ends it.
    /// Fixes15: only a predicate can head that series; noun objects cannot. The comma after a completed series
    /// opens a new clause, including after an objectless infinitive series.
    static let subordinateMarkers: Set<String> = ["i", "we", "you", "they", "he", "she", "it", "people", "to", "should",
                                                  "must", "would", "could", "can", "do", "does", "did", "might", "may",
                                                  "will", "shall"]

    static let seriesConnectors: Set<String> = [",", "and", "or", "then", "plus", "also"]
    static let nounDeterminers: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "my", "your",
                                              "our", "their", "his", "her", "its", "some", "any", "each", "every"]
    /// Lowercased platform/tool names whose final s is not a plural ending.
    static let nonPluralModifiers: Set<String> = ["windows", "macos", "ios", "tvos", "watchos", "jenkins", "kubernetes"]
    /// Quantity words can stand for a plural subject ("these two build", "the many build").
    static let pluralQuantifiers: Set<String> = ["both", "all", "many", "several", "few", "two", "three", "four", "five",
                                                "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                                                "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
                                                "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
                                                "hundred", "thousand", "million", "billion"]

    static func isVerb(_ word: String) -> Bool { changeVerbs.contains(word) || codingOnlyVerbs.contains(word) }

    /// A series needs a predicate, not just a word that can be a verb ("the build", "run the unit test").
    /// Accept a subject/modal/infinitive marker, or an uncoordinated finite noun-subject clause
    /// ("why the developers build"). A marker-led finite predicate rules out the object fallback.
    static func isSeriesHead(_ words: [String], at index: Int, embedded: Embedding, coordinated: Bool) -> Bool {
        guard index > 0, isVerb(words[index]) else { return false }
        let previous = words[index - 1]
        if subordinateMarkers.contains(previous)
            || (previous == "also" && index > 1 && subordinateMarkers.contains(words[index - 2])) { return true }
        let compoundNoun = codePhrases.contains { $0 == previous + " " + words[index] }
        return embedded == .clause && !coordinated && !followsDeterminer(words, at: index) && !compoundNoun
    }

    /// A plural-subject hint: quantity words or an s suffix, excluding known names and -ss/-us/-is.
    static func looksPlural(_ word: String) -> Bool {
        if nonPluralModifiers.contains(word) { return false }
        return pluralQuantifiers.contains(word)
            || (word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("us") && !word.hasSuffix("is"))
    }

    /// Fixes16: true when `words[index]` ends a noun phrase: a determiner, then up to three non-plural modifiers ("the
    /// nightly build", "our slow unit test"). A comma, connector, marker or question word before the determiner ends
    /// the scan. Fixes17: quantity subjects also stop it; digits after a determiner count as quantities, while
    /// version modifiers ("the Windows 11 build") can still reach their determiner.
    static func followsDeterminer(_ words: [String], at index: Int) -> Bool {
        var back = index - 1
        while back >= 0 && back >= index - 4 {
            let word = words[back]
            if nounDeterminers.contains(word) { return true }
            if back > 0 && nounDeterminers.contains(words[back - 1])
                && !word.isEmpty && word.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) { return false }
            if seriesConnectors.contains(word) || subordinateMarkers.contains(word) || questionStarters.contains(word)
                || clauseWords.contains(word) || looksPlural(word) { return false }
            back -= 1
        }
        return false
    }

    /// Index of the last verb when `words[start...]` begins "V2, V3", "V2 and V3" or "V2, and then V3", else nil.
    static func verbSeriesEnd(_ words: [String], from start: Int) -> Int? {
        var index = start
        var last: Int?
        var count = 0
        var closing = false
        while index < words.count && isVerb(words[index]) {
            last = index
            count += 1
            var following = index + 1
            while following < words.count && seriesConnectors.contains(words[following]) { following += 1 }
            if closing || following == index + 1 { break }
            closing = words[(index + 1)..<following].contains { $0 != "," && $0 != "also" }
            index = following
        }
        return count >= 2 ? last : nil
    }

    static func looksLikeCoding(_ text: String) -> Bool {
        requestsCodeInAClause(text) || firstVerbRequestsCode(text)
    }

    /// Where an explanation's scope reaches: "how to build and test" (infinitive) or "why the parser crashes" (clause).
    enum Embedding { case unscoped, infinitive, clause }

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
            var embedded = Embedding.unscoped
            var coordinated = false
            var objected = false
            var innerVerb = false
            var seriesEnded = false
            var index = 0
            while index < words.count {
                let word = words[index]
                index += 1
                let followsSeries = seriesEnded
                seriesEnded = false
                if explains && word == "," && innerVerb,
                   let seriesEnd = verbSeriesEnd(words, from: index) {
                    index = seriesEnd + 1
                    clauseStart = false
                    // A completed series cannot be reused to swallow the next comma's commands.
                    innerVerb = false
                    seriesEnded = true
                    if embedded == .clause { coordinated = true }
                    continue
                }
                let seriesHead = !clauseStart && isSeriesHead(words, at: index - 1, embedded: embedded, coordinated: coordinated)
                innerVerb = false
                if explains && questionStarters.contains(word) && embedded != .infinitive {
                    embedded = index < words.count && words[index] == "to" ? .infinitive : .clause
                    coordinated = false
                    objected = false
                } else if embedded == .infinitive && !["to", "and", "then", "also", "plus", ","].contains(word) && !changeVerbs.contains(word)
                    && !codingOnlyVerbs.contains(word) {
                    objected = true
                }
                if embedded == .clause && index >= 2 && (subordinateMarkers.contains(words[index - 2])
                    || (index >= 3 && words[index - 2] == "also" && subordinateMarkers.contains(words[index - 3])))
                    && (changeVerbs.contains(word) || codingOnlyVerbs.contains(word)) {
                    coordinated = true
                }
                let reopens = (followsSeries && word == ",") || embedded == .unscoped
                    || (embedded == .clause && (word == "," || word == "then" || !coordinated))
                    || (embedded == .infinitive && objected && (word == "," || word == "then"))
                if explains && reopens && (word == "and" || word == "then" || word == "plus") {
                    clauseStart = true
                    embedded = .unscoped
                    coordinated = false
                    continue
                }
                if clauseStart && explainVerbs.contains(word) && (!question || askingVerbs.contains(words[0])) {
                    explains = true
                }
                if word == "," || clauseWords.contains(word) {
                    if (!question || explains) && reopens {
                        clauseStart = true
                        embedded = .unscoped
                        coordinated = false
                    }
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
                innerVerb = seriesHead
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

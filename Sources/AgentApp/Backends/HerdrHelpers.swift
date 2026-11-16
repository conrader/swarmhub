import Foundation

/// Helper agents. A bot's agent can hand a task to another agent with `swarmhub-herdr helper start` in its own
/// shell; the bridge starts it on the runtime and model its policy gives that difficulty, and ends it with the agent
/// that started it. The app only reads them: which helpers an agent has, and each helper's task, tool calls, replies
/// and terminal. Foundation only, like the rest of `HerdrClient`.
extension HerdrClient {
    /// An agent as the bridge names one in a path: its terminal's address and creation time.
    struct AgentRef: Decodable, Sendable, Hashable { let address: String; let createdMs: UInt64 }

    /// One helper in `GET /api/agents/{address}/{created_ms}/helpers`.
    struct Helper: Decodable, Sendable, Equatable, Identifiable {
        /// The latest saved reply, cut by the bridge when long (`truncated`); the history has it in full.
        struct Reply: Decodable, Sendable, Equatable { let id: Int; let text: String; var truncated: Bool? = nil }
        let address: String; let createdMs: UInt64; let name: String
        var template: String? = nil; var model: String? = nil; var difficulty: String? = nil; var task: String? = nil
        /// `live`, `finished`, or `gone` when Core no longer has the terminal.
        let state: String
        var status: Agent.Status? = nil
        /// Whether a reply was saved after its latest task.
        var answered: Bool? = nil
        var reply: Reply? = nil

        var id: String { "\(address)/\(createdMs)" }
        var ref: AgentRef { AgentRef(address: address, createdMs: createdMs) }
        var isLive: Bool { state == "live" }
        var isWorking: Bool { isLive && status?.state == "working" }

        /// A few words on what the helper is doing.
        var statusLine: String {
            switch state {
            case "live":
                switch status?.state {
                case "working": "Working"
                case "blocked": "Waiting at a prompt"
                case "error": "Reported an error"
                case "done" where answered != true: "Finishing"
                default: answered == true ? "Answered" : "Starting"
                }
            case "finished": answered == true ? "Ended after answering" : "Ended without an answer"
            default: "No longer on the server"
            }
        }

        /// "easy · model": the difficulty the agent chose and the model the server's policy gave it.
        var runLine: String { [difficulty, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    /// An agent's running helpers, newest first. `limit`: how many it may have running at once; nil without a usable
    /// policy. `stopAfterSeconds`: how long after its answer the server stops an idle helper, which then leaves the list.
    struct Helpers: Decodable, Sendable, Equatable {
        let core: String; let parent: AgentRef; var limit: Int? = nil; var stopAfterSeconds: Int? = nil; let helpers: [Helper]
    }

    /// What a helper did, for the read-only view: every task it was given and every reply it saved (oldest first),
    /// the tool calls of its launch, the reply it is writing, and its terminal's screen (nil when Core has none).
    struct HelperLog: Sendable, Equatable {
        var tasks: [Item] = []; var replies: [Item] = []; var tools: [ToolCall] = []; var draft: String? = nil; var screen: String? = nil
        /// The latest reply in full; while the helper writes the next one (`answered` is false), that text so far.
        func latestReply(answered: Bool) -> String? {
            let writing = draft.flatMap { $0.isEmpty ? nil : $0 }
            return answered ? replies.last?.text ?? writing : writing ?? replies.last?.text
        }
    }

    func helpers(of agent: AgentRef) async throws -> Helpers { try await get("/api/agents/\(agent.address)/\(agent.createdMs)/helpers") }

    /// The agent's terminal as text: what its screen shows now.
    func screen(of agent: AgentRef) async throws -> String {
        struct Output: Decodable { let text: String }
        let output: Output = try await get("/api/agents/\(agent.address)/\(agent.createdMs)/output")
        return Self.screenText(output.text)
    }

    /// The saved rows are the log; the tool calls and the screen are extras that a helper which has ended may no
    /// longer have, so a failed read of either leaves that part out.
    func helperLog(core: String, helper: AgentRef) async throws -> HelperLog {
        let items = try await history(core: core, address: helper.address, createdMs: helper.createdMs)
        let seen = try? await preview(core: core, address: helper.address, createdMs: helper.createdMs)
        return HelperLog(tasks: items.filter { $0.kind == "task" }, replies: items.filter { $0.kind == "reply" }, tools: seen?.tools ?? [], draft: seen?.draft,
                         screen: try? await screen(of: helper))
    }

    /// The agent's helpers when the workspace shows it has any; an agent without one costs no second request.
    func helpers(of agent: Agent, in workspace: Workspace) async throws -> Helpers? {
        guard workspace.agents.contains(where: { $0.parent == agent.ref }) else { return nil }
        return try await helpers(of: agent.ref)
    }

    static let screenBytes = 48_000

    /// A terminal screen as plain lines: no escape sequences or other control characters, no trailing blanks, and
    /// only the last `screenBytes` of a long one.
    static func screenText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // CSI and OSC sequences, should Core ever pass them through.
        for pattern in ["\u{1B}\\[[0-9;?]*[ -/]*[@-~]", "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        var lines = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control }))
            .components(separatedBy: "\n").map { line in String(line.reversed().drop(while: { $0 == " " }).reversed()) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var kept: [String] = [], bytes = 0
        for line in lines.reversed() {
            bytes += line.utf8.count + 1
            if bytes > screenBytes { break }
            kept.append(line)
        }
        return kept.reversed().joined(separator: "\n")
    }
}

/// What a bot that may start helpers is told (its "Can start helper agents" switch). The server's policy decides
/// what each difficulty runs on, so the note names no model and the agent is told that it cannot choose one.
enum HerdrHelperNote {
    /// Only this note (and a person quoting the command) contains it: `HerdrClient.deliver` tells an agent once.
    static let marker = "swarmhub-herdr helper start"
    static let difficulties = ["easy", "medium", "hard"]

    static let text = """
        You can hand a self-contained subtask to a helper agent that works on its own while you carry on. In your shell run:

        \(marker) --difficulty \(difficulties.joined(separator: "|")) [--name NAME] [--here] "TASK"

        then `swarmhub-herdr helper wait NAME` for its answer. `swarmhub-herdr helper list` shows your helpers, \
        `helper read NAME` its latest answer, `helper send NAME "TEXT"` gives it a follow-up and `helper stop NAME` ends it. \
        The helper knows nothing of this conversation: put everything it needs into TASK. It starts in the server's \
        agent folder, or with --here in the folder you run the command in. \
        Choose the difficulty honestly: easy for small mechanical edits, medium for normal features and fixes, hard for \
        design-heavy or risky work. The server picks the helper's model from the difficulty; you cannot choose it, and \
        a higher difficulty than the task needs only costs more. The server limits how many helpers you may have at \
        once and tells you when a start is refused. It stops a helper a short while after it has answered, unless you \
        send it a follow-up first; its answer stays readable with `helper read NAME`. Check a helper's answer before you \
        rely on it, and do small things yourself.
        """
}

/// The server's helper policy (`GET` and `POST /api/helper-policy`): which template and model each difficulty runs
/// on, how many helpers one agent may have at once, and how long an idle helper stays after its answer. A difficulty
/// that is left out is refused. The server owns it; the app only edits it, with choices the server itself offers.
struct HerdrHelperPolicy: Decodable, Sendable, Equatable {
    struct Tier: Decodable, Sendable, Equatable { var template: String; var model: String }
    var maxRunning: Int
    var stopAfterSeconds: Int
    var difficulties: [String: Tier]

    /// The `POST` body, in the bridge's own field names.
    var body: [String: Any] {
        ["max_running": maxRunning, "stop_after_seconds": stopAfterSeconds,
         "difficulties": difficulties.mapValues { ["template": $0.template, "model": $0.model] }]
    }
}

/// What `GET /api/helper-policy` answers (a `POST` that saved answers the same): the saved policy, nil when there is
/// none the server can apply; why helpers cannot start as things are; and the ranges the server accepts.
struct HerdrHelperSettings: Decodable, Sendable, Equatable {
    struct Range: Decodable, Sendable, Equatable { let min: Int; let max: Int; var `default`: Int? = nil }
    struct Bounds: Decodable, Sendable, Equatable { var maxRunning: Range? = nil; var stopAfterSeconds: Range? = nil }
    var policy: HerdrHelperPolicy? = nil
    var problem: String? = nil
    var bounds: Bounds? = nil
}

extension HerdrClient {
    func helperSettings() async throws -> HerdrHelperSettings { try await get("/api/helper-policy") }

    /// Replaces the policy. The server saves it only when every choice in it can be started now; otherwise it throws
    /// with the server's own sentence and nothing is changed.
    func saveHelperPolicy(_ policy: HerdrHelperPolicy) async throws -> HerdrHelperSettings { try await post("/api/helper-policy", policy.body) }
}

/// The helper settings as a form edits them. Everything offered comes from the server: its templates, each
/// template's models, and its ranges. The app names no model.
struct HerdrHelperPolicyDraft: Equatable, Sendable {
    /// Per difficulty; a difficulty with no template is not allowed.
    var tiers: [String: HerdrHelperPolicy.Tier] = [:]
    var maxRunning = 3
    var stopAfterSeconds = 60
    var runningRange = 0...16
    var stopAfterRange = 5...86_400

    init() {}

    init(_ settings: HerdrHelperSettings) {
        if let range = settings.bounds?.maxRunning, range.min <= range.max { runningRange = range.min...range.max }
        if let range = settings.bounds?.stopAfterSeconds, range.min <= range.max { stopAfterRange = range.min...range.max }
        stopAfterSeconds = settings.policy?.stopAfterSeconds ?? settings.bounds?.stopAfterSeconds?.default ?? stopAfterSeconds
        maxRunning = settings.policy?.maxRunning ?? maxRunning
        tiers = (settings.policy?.difficulties ?? [:]).filter { HerdrHelperNote.difficulties.contains($0.key) }
        maxRunning = min(max(maxRunning, runningRange.lowerBound), runningRange.upperBound)
        stopAfterSeconds = min(max(stopAfterSeconds, stopAfterRange.lowerBound), stopAfterRange.upperBound)
    }

    var policy: HerdrHelperPolicy {
        HerdrHelperPolicy(maxRunning: maxRunning, stopAfterSeconds: stopAfterSeconds, difficulties: tiers.filter { !$0.value.template.isEmpty && !$0.value.model.isEmpty })
    }

    /// A difficulty with a template but no model yet cannot be saved.
    var problem: String? {
        HerdrHelperNote.difficulties.first { tiers[$0].map { !$0.template.isEmpty && $0.model.isEmpty } == true }.map { "Choose a model for \($0) helpers." }
    }

    /// Chooses the template for a difficulty ("" turns the difficulty off). The model becomes the first one the server
    /// offers for that template, unless the current one is offered too.
    mutating func setTemplate(_ template: String, for difficulty: String, offered: [HerdrClient.Template.Model]) {
        guard !template.isEmpty else { tiers[difficulty] = nil; return }
        let current = tiers[difficulty]?.model ?? ""
        tiers[difficulty] = .init(template: template, model: offered.contains { $0.id == current } ? current : offered.first?.id ?? "")
    }

    /// The templates a helper can run on: usable ones that start their agent on a chosen model.
    static func templates(in all: [HerdrClient.Template]) -> [HerdrClient.Template] { all.filter { $0.error == nil && $0.takesModel } }

    /// The delays the picker offers: round ones inside the server's range, and the saved one whatever it is.
    func delays() -> [Int] {
        Array(Set([15, 30, 60, 120, 300, 900, 3_600].filter { stopAfterRange.contains($0) } + [stopAfterSeconds])).sorted()
    }

    /// "45 seconds", "1 minute", "5 minutes", "1 hour"; an uneven value keeps its seconds.
    static func delayLabel(_ seconds: Int) -> String {
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        if seconds >= 3_600, seconds % 3_600 == 0 { return count(seconds / 3_600, "hour") }
        if seconds >= 60, seconds % 60 == 0 { return count(seconds / 60, "minute") }
        return count(seconds, "second")
    }
}

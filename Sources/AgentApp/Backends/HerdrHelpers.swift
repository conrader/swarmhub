import Foundation

/// Helper agents. A bot's agent can hand a task to another agent with `swarmhub-herdr helper start` in its own
/// shell; the bridge starts it on the runtime and model its policy gives that difficulty, and ends it with the agent
/// that started it. This client reads each helper's task, tool calls, replies and terminal. Foundation only, like the rest of `HerdrClient`.
extension HerdrClient {
    /// An agent as the bridge names one in a path: its terminal's address and creation time.
    struct AgentRef: Codable, Sendable, Hashable { let address: String; let createdMs: UInt64 }

    struct ArchivedHelperParent: Decodable, Equatable, Sendable {
        let core: String
        let agent: String
        let session: AgentRef
        let delegatedBy: AgentRef?
        let revision: Int64
    }

    /// One helper in `GET /api/agents/{address}/{created_ms}/helpers`.
    struct Helper: Decodable, Sendable, Equatable, Identifiable {
        /// The latest saved reply, cut by the bridge when long (`truncated`); the history has it in full.
        struct Reply: Decodable, Sendable, Equatable { let id: Int; let text: String; var truncated: Bool? = nil; var atMs: Int64? = nil }
        let address: String; let createdMs: UInt64; let name: String
        /// `modelLabel`: the model's name as people read it ("Sonnet 5.5"), from a server that sends it (`model_label`).
        var template: String? = nil; var model: String? = nil; var modelLabel: String? = nil; var difficulty: String? = nil; var task: String? = nil
        /// The latest follow-up when the workspace includes it. Older listings carry only the launch task.
        var currentTask: String? = nil
        var openTask: Bool? = nil
        var sidebarSummary: String? = nil
        var assignment: String? { currentTask ?? task }
        /// `live`, `finished`, or `gone` when Core no longer has the terminal.
        let state: String
        var status: Agent.Status? = nil
        /// Whether a reply was saved after its latest task.
        var answered: Bool? = nil
        var reply: Reply? = nil

        var id: String { "\(address)/\(createdMs)" }
        var ref: AgentRef { AgentRef(address: address, createdMs: createdMs) }
        var isLive: Bool { state == "live" }
        var hasOpenTask: Bool { isLive && answered != true && (openTask ?? !["blocked", "error", "done"].contains(status?.state ?? "")) }
        var resultPreview: String? {
            guard answered == true, let text = reply?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var isWorking: Bool { isLive && status?.state == "working" }

        /// The process can report new activity after saving a reply.
        var showingAnswer: Bool {
            answered == true && !(isLive && ["working", "blocked", "error"].contains(status?.state ?? ""))
        }

        /// A few words on what the helper is doing.
        var statusLine: String {
            if showingAnswer { return "Answered" }
            return switch state {
            case "live":
                switch status?.state {
                case "working": "Working"
                case "blocked": "Waiting for an answer in its terminal"
                case "error": "Reported an error"
                case "done": "Finishing"
                default: "Starting"
                }
            case "finished": "Stopped without an answer"
            case "gone": "Session ended"
            default: "Gone"
            }
        }

        /// The model the helper runs on, by its label: the server's, else the one the app saw for that id, else the id.
        var runLine: String { [modelLabel, HerdrModelNames.label(model), model].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        var taskLine: String { (assignment ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        /// "Easy task": how hard the bot said the task is, for the helper's own view.
        var difficultyLine: String? { difficulty.flatMap { $0.isEmpty ? nil : "\($0.prefix(1).uppercased())\($0.dropFirst()) task" } }
    }

    enum ChildRuntime: String, Codable, Sendable {
        case claude, codex, opencode, gemini
        var label: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .opencode: "OpenCode"
            case .gemini: "Gemini CLI"
            }
        }
    }

    struct NativeThread: Decodable, Sendable, Hashable, Identifiable {
        let id: String
        let parent: String
        var runtime: ChildRuntime? = nil
        var provider: ChildRuntime { runtime ?? .codex }
        let name: String
        let model: String?
        let createdMs: Int64
        var completedMs: Int64? = nil
        let state: String
        let task: String
        let reply: String
        var taskName: String? = nil
        var sidebarSummary: String? = nil

        var isWorking: Bool { state == "working" }
        var sessionDetail: String { [provider.label + " session", model].compactMap { $0 }.joined(separator: " · ") }
        var modelLine: String {
            guard let model, !model.isEmpty else { return provider.label }
            return provider.label + " · " + model
        }
        var statusLine: String { Self.statusLabel(state) }

        static func statusLabel(_ state: String) -> String {
            switch state {
            case "working": "Working"
            case "answered": "Answered"
            case "error": "Reported an error"
            case "stopped": "Stopped"
            case "finished": "Finished"
            default: "Status unavailable"
            }
        }
    }

    /// An agent's running helpers, newest first. `limit`: how many it may have running at once; nil without a usable
    /// policy. `stopAfterSeconds`: how long after its answer the server stops an idle helper, which then leaves the list.
    struct Helpers: Decodable, Sendable, Equatable {
        let core: String; let parent: AgentRef; var limit: Int? = nil; var stopAfterSeconds: Int? = nil; let helpers: [Helper]

        var codexThreads: [NativeThread]? = nil
        var claudeThreads: [NativeThread]? = nil
        var opencodeThreads: [NativeThread]? = nil
        var geminiThreads: [NativeThread]? = nil
        var nativeThreads: [NativeThread] { [codexThreads, claudeThreads, opencodeThreads, geminiThreads].compactMap { $0 }.flatMap { $0 } }
        var hasSidebarSessions: Bool { !nativeThreads.isEmpty || !sidebarSessions.isEmpty }

        var lastResult: Helper? = nil
        var recentSessions: [Helper]? = nil

        var sidebarSessions: [Helper] {
            var seen = Set<String>()
            return (helpers + [lastResult].compactMap { $0 } + (recentSessions ?? [])).filter { seen.insert($0.id).inserted }
        }

        /// Keep the latest answer visible across its terminal closing and while other helpers work.
        var inChat: [Helper] {
            let candidates = helpers + [lastResult].compactMap { $0 }
            let latest = candidates.filter { $0.resultPreview != nil }.max { ($0.reply?.id ?? 0) < ($1.reply?.id ?? 0) }
            let live = helpers.filter(\.isLive)
            guard let latest, !live.contains(where: { $0.id == latest.id }) else { return live }
            return live + [latest]
        }
    }

    /// What a helper did, for the read-only view: every task it was given and every reply it saved (oldest first),
    /// the tool calls of its launch, the reply it is writing, and its terminal's screen (nil when Core has none).
    struct HelperLog: Sendable, Equatable {
        var tasks: [Item] = []; var replies: [Item] = []; var tools: [ToolCall] = []; var draft: String? = nil; var screen: String? = nil
        /// Workspace publications keep their journal IDs and position even when a helper never sends text.
        var publications: [Item] = []

        func results(forReply id: Int) -> [HerdrPublishedResult] {
            guard !publications.isEmpty else { return [] }
            let after = tasks.last(where: { $0.id < id })?.id ?? 0
            // A steer can arrive before the previous task answers. Keep the file cards in the
            // transcript, but do not resolve its links against the steer's publications.
            if let task = replies.first(where: { $0.id == id })?.answerTo?.id, task != after { return [] }
            let before = tasks.first(where: { $0.id > id })?.id ?? Int.max
            return publications.filter { $0.id > after && $0.id < before }.compactMap(HerdrPublishedResult.init)
        }

        /// The latest reply in full; while the helper writes the next one (`answered` is false), that text so far.
        func latestReply(answered: Bool) -> String? {
            let writing = draft.flatMap { $0.isEmpty ? nil : $0 }
            return answered ? replies.last?.text ?? writing : writing ?? replies.last?.text
        }
    }

    struct ThreadActivity: Decodable {
        struct Details: Decodable {
            struct Step: Decodable {
                let text: String
                let state: String?
                var tool: String? = nil
                var startedMs: Int64? = nil
                var completedMs: Int64? = nil
                var durationMs: Int64? = nil
            }
            let task: String
            let reply: String
            struct Terminal: Decodable {
                let command: String
                let output: String
            }
            let steps: [Step]
            let terminal: Terminal?
        }
        let details: Details?
        let transcript: String
        let state: String
        let activeTurn: String?
        var stopRequested: Bool? = nil
    }

    private func threadRoute(_ runtime: ChildRuntime, owner: AgentRef, core: String, thread: String) -> String {
        let encodedCore = core.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/api/agents/\(owner.address)/\(owner.createdMs)/\(runtime.rawValue)-threads/\(thread)?core=\(encodedCore)"
    }

    func threadActivity(_ runtime: ChildRuntime, owner: AgentRef, core: String, thread: String) async throws -> ThreadActivity {
        try await get(threadRoute(runtime, owner: owner, core: core, thread: thread))
    }

    func requestClaudeStop(_ turn: String, owner: AgentRef, core: String, thread: String) async throws {
        struct Receipt: Decodable { let requestedTurn: String }
        let result: Receipt = try await post(threadRoute(.claude, owner: owner, core: core, thread: thread), ["turn": turn])
        guard result.requestedTurn == turn else { throw BackendError.unavailable("The workspace could not confirm the stop request.") }
    }

    func interruptChildTurn(_ turn: String, runtime: ChildRuntime, owner: AgentRef, core: String, thread: String) async throws {
        struct Receipt: Decodable { let interruptedTurn: String }
        let result: Receipt = try await post(threadRoute(runtime, owner: owner, core: core, thread: thread), ["turn": turn])
        guard result.interruptedTurn == turn else { throw BackendError.unavailable("\(runtime.label) did not confirm this turn.") }
    }

    func helpers(of agent: AgentRef, core: String? = nil) async throws -> Helpers {
        let query = core.map { "?core=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") } ?? ""
        return try await get("/api/agents/\(agent.address)/\(agent.createdMs)/helpers" + query)
    }

    /// The agent's terminal as text: what its screen shows now.
    func screen(of agent: AgentRef) async throws -> String {
        struct Output: Decodable { let text: String }
        let output: Output = try await get("/api/agents/\(agent.address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? agent.address)/\(agent.createdMs)/output")
        return Self.screenText(output.text)
    }

    /// The saved rows are the log; the tool calls and the screen are extras that a helper which has ended may no
    /// longer have, so a failed read of either leaves that part out.
    func helperLog(core: String, helper: AgentRef, includeScreen: Bool = true) async throws -> HelperLog {
        let items = try await history(core: core, address: helper.address, createdMs: helper.createdMs)
        let seen = try? await preview(core: core, address: helper.address, createdMs: helper.createdMs)
        return HelperLog(tasks: items.filter { $0.kind == "task" }, replies: items.filter { $0.kind == "reply" }, tools: seen?.tools ?? [], draft: seen?.draft,
                         screen: includeScreen ? try? await screen(of: helper) : nil,
                         publications: items.filter { HerdrPublishedResult($0) != nil })
    }

    /// The agent's helpers when the workspace shows it has any; an agent without one costs no second request.
    func helpers(of agent: Agent, in workspace: Workspace, includeLastResult: Bool = false) async throws -> Helpers? {
        let hasSavedSessions = workspace.helperSessionParents.map { $0.contains(agent.ref) }
            ?? (includeLastResult && workspace.helperResults == true)
        guard hasSavedSessions || workspace.agents.contains(where: { $0.parent == agent.ref }) else { return nil }
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
    static let marker = "After a background helper"
    static let difficulties = ["easy", "medium", "hard"]

    static let text = """
        Delegate a self-contained task in your shell:
        swarmhub-herdr helper start --difficulty \(difficulties.joined(separator: "|")) [--name NAME] [--here] "TASK"

        \(marker) starts, its result appears in chat. If you owe the user another step, before ending your turn use the \
        start receipt’s exact `helper after NAME "NEXT STEP"` command. On older workspaces, plan a check-in. \
        Acknowledge the handoff and leave chat available. Use `helper wait NAME` for foreground work. \
        `helper list` lists helpers, `helper read NAME` reads the result, `helper send NAME "TEXT"` assigns more work, \
        and `helper stop NAME` ends it. Include the context the helper needs in TASK. Use --here to share your working directory.
        Choose easy for small mechanical edits, medium for normal features and fixes, hard for design-heavy or risky work. \
        The server uses the person's helper model choice for this bot or its default for the difficulty. It limits concurrent helpers \
        and stops a helper a short while after it has answered. Check the saved answer before relying on it.
        If an optional helper is unavailable, continue authorized work directly. Ask for a decision only when it blocks the user’s objective.
        """
}

/// The server's helper policy (`GET` and `POST /api/helper-policy`): which template and model each difficulty runs
/// on, how many helpers one agent may have at once, how long an idle helper stays after its answer, and how long a
/// helper may go without answering before it is stopped. A difficulty that is left out is refused. The server owns
/// it; the app only edits it, with choices the server itself offers.
struct HerdrHelperPolicy: Decodable, Sendable, Equatable {
    struct Tier: Decodable, Sendable, Equatable { var template: String; var model: String }
    var maxRunning: Int
    var stopAfterSeconds: Int
    /// nil from a server that does not have this setting yet; then it is not sent back either, because that server
    /// refuses a field it does not know.
    var stopUnansweredAfterSeconds: Int? = nil
    var difficulties: [String: Tier]

    /// The `POST` body, in the bridge's own field names.
    var body: [String: Any] {
        var body: [String: Any] = ["max_running": maxRunning, "stop_after_seconds": stopAfterSeconds,
                                   "difficulties": difficulties.mapValues { ["template": $0.template, "model": $0.model] }]
        body["stop_unanswered_after_seconds"] = stopUnansweredAfterSeconds
        return body
    }
}

/// What `GET /api/helper-policy` answers (a `POST` that saved answers the same): the saved policy, nil when there is
/// none the server can apply; why helpers cannot start as things are; and the ranges the server accepts.
struct HerdrHelperSettings: Decodable, Sendable, Equatable {
    struct Range: Decodable, Sendable, Equatable { let min: Int; let max: Int; var `default`: Int? = nil }
    struct Bounds: Decodable, Sendable, Equatable { var maxRunning: Range? = nil; var stopAfterSeconds: Range? = nil; var stopUnansweredAfterSeconds: Range? = nil }
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
    /// How long a helper may go without answering; nil when the server has no such setting (an older workspace).
    var stopUnansweredSeconds: Int? = nil
    var runningRange = 0...16
    var stopAfterRange = 5...86_400
    var stopUnansweredRange = 60...604_800

    init() {}

    init(_ settings: HerdrHelperSettings) {
        if let range = settings.bounds?.maxRunning, range.min <= range.max { runningRange = range.min...range.max }
        if let range = settings.bounds?.stopAfterSeconds, range.min <= range.max { stopAfterRange = range.min...range.max }
        stopAfterSeconds = settings.policy?.stopAfterSeconds ?? settings.bounds?.stopAfterSeconds?.default ?? stopAfterSeconds
        maxRunning = settings.policy?.maxRunning ?? maxRunning
        tiers = (settings.policy?.difficulties ?? [:]).filter { HerdrHelperNote.difficulties.contains($0.key) }
        maxRunning = min(max(maxRunning, runningRange.lowerBound), runningRange.upperBound)
        stopAfterSeconds = min(max(stopAfterSeconds, stopAfterRange.lowerBound), stopAfterRange.upperBound)
        if let range = settings.bounds?.stopUnansweredAfterSeconds, range.min <= range.max { stopUnansweredRange = range.min...range.max }
        stopUnansweredSeconds = (settings.policy?.stopUnansweredAfterSeconds ?? settings.bounds?.stopUnansweredAfterSeconds?.default)
            .map { min(max($0, stopUnansweredRange.lowerBound), stopUnansweredRange.upperBound) }
    }

    var policy: HerdrHelperPolicy {
        HerdrHelperPolicy(maxRunning: maxRunning, stopAfterSeconds: stopAfterSeconds, stopUnansweredAfterSeconds: stopUnansweredSeconds,
                          difficulties: tiers.filter { !$0.value.template.isEmpty && !$0.value.model.isEmpty })
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

    /// The same for a helper that never answers: longer waits, since a helper may work on one task for a while.
    func unansweredDelays() -> [Int] {
        guard let stopUnansweredSeconds else { return [] }
        return Array(Set([300, 900, 1_800, 3_600, 7_200, 14_400, 28_800, 86_400].filter { stopUnansweredRange.contains($0) } + [stopUnansweredSeconds])).sorted()
    }

    /// "45 seconds", "1 minute", "5 minutes", "1 hour"; an uneven value keeps its seconds.
    static func delayLabel(_ seconds: Int) -> String {
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        if seconds >= 3_600, seconds % 3_600 == 0 { return count(seconds / 3_600, "hour") }
        if seconds >= 60, seconds % 60 == 0 { return count(seconds / 60, "minute") }
        return count(seconds, "second")
    }
}

extension HerdrClient {
    struct BotAgentSettings: Decodable {
        struct Candidate: Decodable, Identifiable {
            let id, name, model: String
            var label: String {
                let display = model == "@provider-default" ? "Claude default" : model
                return Approval.visible(name + " · " + display)
            }
        }
        let choice: HerdrHelperPolicy.Tier?
        let autoMode: Bool
        var reviewEveryTool: Bool? = nil
        var documentReadOnly: Bool? = nil
        var sessionCapCents: Int? = nil
        var autoChangedMs: UInt64? = nil
        var commandReviewer: String? = nil
        var reviewerBotId: String? = nil
        var reviewerBots: [Candidate]? = nil

        var reviewerLabel: String {
            if let id = reviewerBotId {
                return reviewerBots?.first(where: { $0.id == id })?.label ?? "Selected bot unavailable"
            }
            guard let model = commandReviewer, model != "off" else { return "Off" }
            return "Claude " + model.capitalized
        }
    }

    func botAgentSettings(for bot: UUID) async throws -> BotAgentSettings {
        try await get("/api/bot-agent-settings/\(bot.uuidString.lowercased())")
    }

    func setHelperModel(_ tier: HerdrHelperPolicy.Tier?, for bot: UUID, existingAgents: [String]) async throws -> BotAgentSettings {
        let choice: Any = tier.map { ["template": $0.template, "model": $0.model] as Any } ?? NSNull()
        return try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", ["choice": choice, "existing_agents": existingAgents])
    }
    func setCommandReviewer(_ model: String, for bot: UUID, existingAgents: [String]) async throws -> BotAgentSettings {
        try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", model.hasPrefix("bot:") ? ["reviewer_bot_id": String(model.dropFirst(4)), "existing_agents": existingAgents] : ["command_reviewer": model, "existing_agents": existingAgents])
    }
    func enableDocumentReview(for bot: UUID) async throws -> BotAgentSettings {
        try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", ["document_read_only": true])
    }

    func setSessionCap(_ cents: Int, for bot: UUID) async throws -> BotAgentSettings {
        try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", ["session_cap_cents": cents])
    }

    func setToolReview(_ enabled: Bool, for bot: UUID, existingAgents: [String] = []) async throws -> BotAgentSettings {
        try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", ["review_every_tool": enabled, "existing_agents": existingAgents])
    }

    func setProjectAutoMode(_ enabled: Bool, for bot: UUID, existingAgents: [String]) async throws -> BotAgentSettings {
        try await post("/api/bot-agent-settings/\(bot.uuidString.lowercased())", ["auto_mode": enabled, "existing_agents": existingAgents])
    }

}

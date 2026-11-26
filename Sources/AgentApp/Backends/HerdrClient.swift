import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The SwarmHub bridge that runs beside Herdr Core (`HerdrWorkspace/`, `swarmhub-herdr`), over its local HTTP API.
/// Herdr Core runs agent programs in terminals; the bridge launches them from Core's templates, types tasks into them
/// and saves each finished reply through the agent's own Stop hook. This client only talks to the bridge.
///
/// The bridge listens on loopback and refuses any request whose `Host` is not `127.0.0.1:<port>` or
/// `localhost:<port>`; a `POST` must also carry the matching `Origin`. An app-managed SSH forward can listen on
/// another local port while sending the bridge’s own Host and Origin. Foundation only for Linux checks.
struct HerdrClient: Sendable {
    struct Template: Decodable, Sendable, Equatable {
        /// On a template: its agent program. On a saved session (`Profile.Session`): also the model the agent was
        /// started on, `modelId` and its `model` label, both nil when it was started without one.
        struct Runtime: Decodable, Sendable, Equatable {
            let harness: String?; let provider: String?; let model: String?; var modelId: String? = nil
            /// The short name people call the agent program by ("Claude"), when the server sends one (`display_name`).
            var displayName: String? = nil
        }
        /// A model the template offers by name (the bridge's `runtime-catalog.json`).
        struct Model: Decodable, Sendable, Equatable { let id: String; let label: String? }
        let name: String; let description: String?; let error: String?; let runtime: Runtime?
        /// Set when the template can start its agent on a chosen model; `discoverModels` when the agent program can list them.
        var supportsToolReview: Bool? = nil
        var supportsSessionCap: Bool? = nil
        var modelAgent: String? = nil; var models: [Model]? = nil; var discoverModels: Bool? = nil
        /// The program is in beta on this server, which then lists it after the others, so it is "the server's
        /// first" only when it is the only one. `note` is the server's one sentence on what it cannot do yet,
        /// shown where a program is chosen (`HerdrProgramNote`). A server from before betas sends neither.
        var beta: Bool? = nil; var note: String? = nil
        var takesModel: Bool { modelAgent != nil }
        /// The agent program by the name people use for it ("Claude"): the server's `display_name`, else the program's
        /// own name without a word that only says what kind of program it is (`HerdrProgramName`). nil when the
        /// template names no program.
        var programName: String? { HerdrProgramName.friendly(display: runtime?.displayName, program: runtime?.harness) }
        /// What a choice of this template reads as: the program's friendly name, never the template's own name unless
        /// it names no program. Two choices that would read the same are told apart by `HerdrProgramName.labels`.
        var label: String { programName ?? name }

        /// Some runtimes advertise the provider as their display name (Gemini through Antigravity).
        var programDetail: String? {
            guard let program = HerdrProgramName.friendly(display: nil, program: runtime?.harness),
                  program.caseInsensitiveCompare(label) != .orderedSame else { return nil }
            return program
        }
        var pickerLabel: String { programDetail.map { "\(label) · \($0)" } ?? label }
    }

    struct SessionUsage: Decodable, Sendable, Equatable {
        let contextTokens: Int64?
        let windowTokens: Int64?
        let totalTokens: Int64
        let opencodeCostUsd: Double?

        var estimatedCost: String? {
            guard let amount = opencodeCostUsd, amount.isFinite, amount > 0 else { return nil }
            if amount < 0.0001 { return "< " + 0.0001.formatted(.currency(code: "USD").precision(.fractionLength(4))) }
            return amount.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
        }

        var contextPercent: Int? {
            guard let contextTokens, contextTokens >= 0, let windowTokens, windowTokens > 0 else { return nil }
            return Int((100 * min(1, Double(contextTokens) / Double(windowTokens))).rounded())
        }
    }

    struct Agent: Decodable, Sendable, Equatable {
        struct Status: Decodable, Sendable, Equatable { let state: String?; var kind: String? = nil }
        /// Core types the first task only once the agent reports that it is ready; a start-up prompt leaves it unsent.
        struct FirstMessage: Decodable, Sendable, Equatable { let sent: Bool? }
        let address: String; let name: String; let state: String; let createdMs: UInt64; let template: String?; let status: Status?
        var firstMessage: FirstMessage? = nil
        var vaultSessionStale: Bool?
        var autoRestartPending: Bool?
        var sessionUsage: SessionUsage? = nil
        var codexSessionModel: String? = nil
        var codexSandbox: String?
        var codexPolicy: String?
        var codexReviewer: String?
        var codexReviewEvent: String?
        var reviewDescription: String? {
            let reviewer = switch codexReviewer {
            case "user": "This Codex session routes permission requests to you."
            case "auto_review": "This Codex session routes eligible permission requests to automatic review."
            default: ""
            }
            let event = switch codexReviewEvent {
            case "human_requested": "Codex asked for a human decision on its last permission request."
            case "auto_approved": "Automatic review approved the last request."
            case "auto_denied": "Automatic review denied the last request."
            case "auto_incomplete": "Automatic review did not complete."
            default: ""
            }
            let mode = [codexSandbox, codexPolicy].compactMap { $0 }.joined(separator: " · ")
            return [mode, reviewer, event].filter { !$0.isEmpty }.isEmpty ? nil : [mode, reviewer, event].filter { !$0.isEmpty }.joined(separator: " ")
        }
        var openCodeFirstTask: String? = nil
        var reason: String? = nil
        /// Set for a helper: the agent that started it (`HerdrHelpers.swift`). A bot's own agent has none.
        var parent: AgentRef? = nil
        /// From a bridge that starts agents ahead of their first message (`warm`). `ready` is false only while such an
        /// agent's program has not reported to Core yet: a message sent then is kept by the bridge and typed when it
        /// has. `warm` stays true until a task has reached the agent, and until then the bridge ends it at
        /// `warmEndsMs` for being idle. An older bridge sends none of them.
        var ready: Bool? = nil, warm: Bool? = nil, warmEndsMs: UInt64? = nil
        var isLive: Bool { state == "live" }
        var ref: AgentRef { AgentRef(address: address, createdMs: createdMs) }
        /// Running, but its program is not ready for a task yet.
        var isStarting: Bool { isLive && ready == false && status?.state != "blocked" }
        func promptFailure(program: String?) -> Failure {
            status?.kind?.lowercased() == "auth"
                ? .signInRequired(ref, program)
                : .waitingAtPrompt
        }

        var isIdleForRollover: Bool {
            switch status?.state {
            case "idle", "done": return (!isStarting || warm == true) && firstMessage?.sent != false
            case nil: return warm == true && firstMessage == nil
            default: return false
            }
        }
    }

    struct Workspace: Decodable, Sendable {
        let core: String?; let version: String?; let agents: [Agent]; let templates: [Template]
        var terminalPreview: Bool? = nil
        var codejobActivity: CodejobActivity? = nil
        /// What the workspace server says it is (`HerdrUpdates.swift`); `version` above is Herdr Core's. A server
        /// from before it said so sends none.
        var bridge: HerdrBridgeInfo? = nil
        var attachments: Bool? = nil
        var botWorkspaces: Bool? = nil
        var routineTransfers: Bool? = nil
        var workspaceRoot: String? = nil
        var endIfIdle: Bool? = nil
        var helperResults: Bool? = nil
        var helperSessionParents: [AgentRef]? = nil
        var archivedHelperParents: [ArchivedHelperParent]? = nil
        var codexTurnSteer: Bool? = nil
        var launchAttachments: Bool? = nil
        func launchTemplate(named name: String?) -> Template? {
            templates.first { $0.error == nil && (name == nil || $0.name == name) }
        }
        /// The server's name for the agent program `agent` runs ("Codex"); nil when its template names none.
        func program(of agent: Agent) -> String? { templates.first { $0.name == agent.template }?.programName }
    }

    /// A bot's saved profile on the bridge, with its newest sessions and what each was launched with.
    struct Profile: Decodable, Sendable {
        struct Session: Decodable, Sendable, Equatable {
            let address: String; let createdMs: UInt64
            var runtime: Template.Runtime? = nil
            var core: String? = nil
        }
        let id: Int; let runtimeName: String
        var sessions: [Session]? = nil
    }

    /// One saved row of a session: `task` (what was sent) or `reply` (what the agent's hook saved).
    /// Other kinds (files, snapshots) carry no text; they decode with an empty one and are skipped.
    /// `state` on a task says how far it got: "sent", "pending" while the bridge keeps it for an agent that is still
    /// starting, "not_sent" when it was never typed (`detail` then says why).
    struct Item: Decodable, Sendable, Equatable {
        let id: Int; let kind: String; let text: String
        var state: String? = nil, detail: String? = nil
        struct Quote: Decodable, Sendable, Equatable { let id: Int }
        var answerTo: Quote?, replyTo: Quote?
        var atMs: Int64?
        var codexModel: String?, codexRerouted: Bool?
        var pageId: Int?, pageRevision: Int?
        enum CodingKeys: CodingKey { case id, kind, text, state, detail, pageId, pageRevision, answerTo, replyTo, atMs, codexModel, codexRerouted }
        init(id: Int, kind: String, text: String, state: String? = nil, detail: String? = nil) { self.id = id; self.kind = kind; self.text = text; self.state = state; self.detail = detail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
            answerTo = try c.decodeIfPresent(Quote.self, forKey: .answerTo)
            replyTo = try c.decodeIfPresent(Quote.self, forKey: .replyTo)
            atMs = try c.decodeIfPresent(Int64.self, forKey: .atMs)
            codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel)
            codexRerouted = try c.decodeIfPresent(Bool.self, forKey: .codexRerouted)
            pageId = try c.decodeIfPresent(Int.self, forKey: .pageId)
            pageRevision = try c.decodeIfPresent(Int.self, forKey: .pageRevision)
            state = try? c.decodeIfPresent(String.self, forKey: .state); detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        }
        /// A task that was never typed into the agent.
        var wasNotSent: Bool { kind == "task" && state == "not_sent" }
        /// The bridge tried to type the task and saw no turn start.
        var startNotObserved: Bool { kind == "task" && state == "start_not_observed" }
        /// Counts tasks that may still be answered, including those whose start the bridge could not observe.
        var reachedAgent: Bool { kind == "task" && !wasNotSent }
    }

    /// A tool call the agent's hooks reported (`tool_activity` in the bridge): `seq` only grows; `detail` is the
    /// command, file, search or address in one line.
    struct ToolCall: Decodable, Sendable, Equatable { let seq: UInt64; let tool: String; let detail: String?; let finished: Bool; let failed: Bool }

    /// A task on its way: the session it went to and the last saved row and tool call before it, so its reply and
    /// its tool calls are the ones after those.
    struct Turn: Sendable, Equatable {
        let core: String; let address: String; let createdMs: UInt64; let after: Int; let launched: Bool
        var steerReference: String? = nil
        var submittedText: String? = nil
        var afterTool: UInt64 = 0
        /// The server's name for the agent program that answers, for the status lines; nil when it gives none.
        var program: String? = nil
        /// The bridge keeps the message for an agent that is still starting, and types it when the agent is ready.
        var queued = false
        /// The agent program is still starting when the turn begins: it was launched for it, or is not ready yet.
        var starting: Bool { launched || queued }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL, unauthorized, refusedHost, http(Int, String), noTemplate, ended, silent, waitingAtPrompt, unconfirmedDelivery, startNotObserved, notDelivered(String?)
        case signInRequired(AgentRef, String?)
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in here, then choose Retry to send your message."
            case .invalidURL: "The server address is not valid. Use http://127.0.0.1:8787, or the port you forwarded."
            case .unauthorized: "The server did not accept the access key. Open Settings → Servers and check the connection."
            case .refusedHost: "The workspace refused the connection address. For an older workspace over SSH, free its matching local port or update the workspace."
            case .http(_, let message): message
            case .noTemplate: "This server has no AI this bot can run on. Choose one in its Details, under Model."
            case .ended: "The bot stopped before it replied. Send your message again."
            case .silent: "The bot finished without a reply. If its chat shows a terminal prompt, choose Answer here to inspect it."
            // The server's own sentence says why and what to look at; without one, the same in the app's words.
            case .notDelivered(let why): why.map { "\($0) Choose Retry in chat once the bot is ready." } ?? "The bot did not get ready. Answer any terminal prompt in this chat, then choose Retry."
            case .unconfirmedDelivery: "The workspace could not confirm delivery. Check the conversation before sending the message again."
            case .startNotObserved: "The bot may not have received your message. Check its terminal or chat before retrying."
            case .waitingAtPrompt: "The first message did not start. If the bot is asking a question, choose Answer here in chat. Once the bot is ready, choose Retry."
            }
        }
    }

    let baseURL: URL
    let token: String
    var forwardedHost: String? = nil
    var session: URLSession = .shared
    /// Between two reads of a session while waiting for its reply, and between two looks at the agent's status.
    var pollInterval: Duration = .milliseconds(400)
    var agentCheckInterval: Duration = .seconds(2)
    /// Retry budget for reading a turn the workspace already accepted. Its command is never submitted again.
    var reconnectLimit: Duration = .seconds(120)
    var busyWaitLimit: Duration = .seconds(300)
    /// Runs before every request. A server reached over SSH opens its port forward here when it is not up
    /// (`HerdrTunnels.ensure`) and returns its current loopback port.
    var prepare: (@Sendable () async throws -> Int)? = nil
    /// How a turn is followed: on the bridge's event stream (`HerdrEvents.swift`), with the polling routes as the
    /// fallback when the stream cannot be opened or keeps breaking; or by polling alone.
    enum Following: Sendable { case stream, polling }
    var following = Following.stream
    /// The body of a streamed answer, chunk by chunk; nil reads it from the network (`HerdrByteStream`). Checks put a
    /// stream that fails or breaks here.
    var byteSource: (@Sendable (URLRequest) -> AsyncThrowingStream<Data, Error>)? = nil
    /// How often in a row a turn's stream may fail to open or break before the turn is polled instead.
    var streamAttempts = 3

    /// `http://127.0.0.1:8787` and the like: http or https, a host, no path beyond `/`.
    static func validatedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false, url.path.isEmpty, url.query == nil else { return nil }
        return url
    }

    /// The bridge accepts 1–32 of `a-z 0-9 . - _` for an agent. `suffix` (from the bot's id) keeps one bot on one
    /// agent when the bot is renamed; the readable part is what shows in Herdr's own lists.
    static func agentName(for display: String, suffix: String) -> String {
        let tail = String(suffix.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(6))
        var slug = ""
        for character in display.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber { slug.append(character) } else if !slug.isEmpty, slug.last != "-" { slug.append("-") }
        }
        while slug.last == "-" { slug.removeLast() }
        slug = String(slug.prefix(32 - tail.count - 1))
        while slug.last == "-" { slug.removeLast() }
        return slug.isEmpty ? "agent-\(tail)" : "\(slug)-\(tail)"
    }

    static func suffix(of name: String) -> String { name.split(separator: "-").last.map(String.init) ?? name }

    // MARK: Requests

    func workspace(includingCodejobs: Bool = false) async throws -> Workspace {
        try await get(includingCodejobs ? "/api/workspace?codejobs=true" : "/api/workspace")
    }
    func profiles() async throws -> [Profile] { try await get("/api/profiles") }

    struct HistoryPage: Decodable { let items: [Item]; let before: Int? }
    func historyPage(core: String, address: String, createdMs: UInt64, before: Int? = nil) async throws -> HistoryPage {
        try await get("/api/history/\(core)/\(address)/\(createdMs)" + (before.map { "?before=\($0)" } ?? ""))
    }

    func history(core: String, address: String, createdMs: UInt64) async throws -> [Item] {
        try await historyPage(core: core, address: address, createdMs: createdMs).items
    }

    /// What a running turn shows before its reply is saved: the reply so far, when the template publishes one, and
    /// the launch's newest tool calls. An older bridge sends no `tools`.
    func preview(core: String, address: String, createdMs: UInt64) async throws -> (draft: String?, tools: [ToolCall]) {
        struct Preview: Decodable { struct Draft: Decodable { let text: String }; let draft: Draft?; let tools: [ToolCall]? }
        let preview: Preview = try await get("/api/history/\(core)/\(address)/\(createdMs)/draft")
        return (preview.draft?.text, preview.tools ?? [])
    }

    /// `projects`: the ids of the projects on other servers the new agent may use (`HerdrProjects.swift`). The bridge
    /// tells the agent about them in its first task itself.
    /// `task` nil starts the agent ahead of time (`"warm": true`): its program starts and waits, and its first task
    /// is the first message sent to it (`deliver`). A bridge that cannot do that refuses the launch.
    func launch(name: String, template: String, task: String?, profileID: Int?, modelID: String? = nil, projects: [Int] = [], workspaceID: UUID? = nil, files: [TaskFile] = [], expectedCore: String? = nil, turnReference: String? = nil) async throws -> Agent {
        var body: [String: Any] = ["name": name, "template": template]
        if let turnReference { body["turn_reference"] = turnReference }
        if let task { body["task"] = task } else { body["warm"] = true }
        if let profileID { body["profile_id"] = profileID }
        if let modelID { body["model_id"] = modelID }
        if !projects.isEmpty { body["projects"] = projects }
        if let workspaceID { body["workspace_id"] = workspaceID.uuidString.lowercased() }
        if !files.isEmpty {
            body["expected_core"] = expectedCore
            return try await postFileTask("/api/agents/with-files", body, files: files)
        }
        return try await post("/api/agents", body)
    }

    /// The models a template can start on: its named ones, and what the agent program lists when it can.
    struct RuntimeAccount: Decodable {
        enum State: String, Decodable { case signedIn = "signed_in", signedOut = "signed_out", unreported }
        let state: State
        let billing: String?
    }

    func runtimeAccount(template: String?) async throws -> RuntimeAccount {
        let path = "/api/runtime-account"
        if let template {
            guard template != ".", template != "..", template.range(of: #"\A[a-z0-9._-]{1,32}\z"#, options: .regularExpression) != nil
            else { throw Failure.invalidURL }
            return try await get(path + "/" + template, timeout: 40)
        }
        return try await get(path, timeout: 40)
    }

    func models(for template: Template) async throws -> [Template.Model] {
        var found = template.models ?? []
        if template.discoverModels == true {
            struct Listed: Decodable { let models: [Template.Model] }
            let listed: Listed = try await post("/api/runtime-models/\(template.name)", [:])
            found += listed.models.filter { model in !found.contains { $0.id == model.id } }
        }
        HerdrModelNames.remember(found)
        return found
    }

    /// The model a bot without one of its own starts on: the first the server offers for its template. The server's
    /// list decides which that is, because the app itself names no model; nil when the server offers none.
    static func defaultModel(offered: [Template.Model]) -> String? { offered.first?.id }

    /// Closes the agent's session; its saved conversation stays in the workspace.
    func end(_ agent: Agent) async throws { try await end(agent.ref) }

    func end(_ agent: AgentRef) async throws {
        struct Ended: Decodable {}
        let _: Ended = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/end", [:])
    }

    func endIfIdle(_ agent: Agent, core: String, workspace: Workspace, unusedOnly: Bool = false) async throws {
        if workspace.endIfIdle != true {
            // Older bridges only expose the exact-session end route. Recheck the
            // launch, its helpers and any outstanding review before using it.
            let reviews = try await pendingApprovals()
            guard !reviews.contains(where: { $0.agent == agent.name }) else {
                throw Failure.notDelivered("Review the existing session’s approval before switching.")
            }
            let live = try await self.workspace()
            guard live.core == core, let current = liveAgent(named: agent.name, in: live),
                  current.ref == agent.ref, current.isIdleForRollover,
                  !unusedOnly || current.warm == true,
                  !live.agents.contains(where: { $0.isLive && $0.parent == agent.ref }) else {
                throw Failure.notDelivered("The existing session changed or is busy.")
            }
            try await end(current)
            return
        }
        struct Ended: Decodable {}
        let _: Ended = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/end-if-idle",
                                      ["expected_core": core, "unused_only": unusedOnly])
    }

    /// Types `text` into the agent. True when the bridge kept it instead, for an agent that was started ahead of
    /// time and is not ready yet: it is saved there, typed as soon as the agent is ready, and never typed twice.
    @discardableResult func message(_ text: String, to agent: Agent, expectedCore: String? = nil, turnReference: String? = nil) async throws -> Bool {
        struct Delivery: Decodable { let status: String?; let queued: Bool? }
        var body = ["text": text]
        body["expected_core"] = expectedCore
        body["turn_reference"] = turnReference
        let delivery: Delivery = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/messages", body)
        return delivery.queued == true
    }

    func interrupt(_ agent: Agent) async throws -> StopOutcome {
        struct Outcome: Decodable { let outcome: String? }
        let result: Outcome = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/interrupt", [:])
        switch result.outcome {
        case "stopped", "exited": return .requested
        case "still_working": return .stillWorking
        default: return .unconfirmed
        }
    }

    // MARK: A turn

    /// The live agent for this bot: the same name, or the same id suffix after a rename. Never a helper, whose
    /// terminal is named by the agent that started it.
    func liveAgent(named name: String, in workspace: Workspace) -> Agent? {
        let live = workspace.agents.filter { $0.isLive && $0.parent == nil }
        return live.first { $0.name == name } ?? live.first { Self.suffix(of: $0.name) == Self.suffix(of: name) }
    }

    /// The Stop hook can save the last reply before Core releases the terminal. A bot ask or routine
    /// can also own it. Only poll the original session, before reading the history cursor or posting.
    func workspaceForDelivery(name: String, status: @Sendable (HerdrTurnStatus) -> Void) async throws -> Workspace {
        let initial = try await workspace()
        guard let agent = liveAgent(named: name, in: initial), agent.status?.state == "working" else { return initial }
        return try await waitForIdle(agent, name: name, core: initial.core, status: status).workspace
    }

    private func waitForIdle(_ agent: Agent, name: String, core: String?, status: @Sendable (HerdrTurnStatus) -> Void) async throws -> (workspace: Workspace, agent: Agent) {
        status(.waitingForIdle)
        let deadline = ContinuousClock.now + busyWaitLimit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: agentCheckInterval)
            let current = try await workspace()
            guard core == current.core, let live = liveAgent(named: name, in: current), live.ref == agent.ref else {
                throw Failure.notDelivered("The workspace session changed while the message was waiting.")
            }
            switch live.status?.state {
            case "working": continue
            case "idle", "done": return (current, live)
            case "blocked": throw live.promptFailure(program: current.program(of: live))
            default: throw Failure.notDelivered("The workspace could not confirm the session was ready.")
            }
        }
        throw Failure.notDelivered("The workspace session is still busy.")
    }

    /// What became of a start ahead of time.
    enum Warmed: Sendable, Equatable {
        /// The bot's agent was running already (it may still be starting): nothing was started. `program` is the
        /// server's name for its agent program.
        case running(Agent, program: String?)
        case started(Agent, program: String?)
        /// The server refused to start this agent program ahead of time: it is an older one that wants a first task,
        /// or the program must be given its first task as it starts.
        case unavailable
    }

    /// Starts this bot's agent ahead of time when none is running, exactly as its first message would (the same name,
    /// template, model and projects), but with no task: the first message then finds it running (`deliver`).
    /// Never a second agent: a running one is returned as it is.
    func warm(name: String, template: String?, model: String? = nil, projects: [HerdrBotProject] = [], workspaceID: UUID? = nil) async throws -> Warmed {
        let current = try await workspace()
        guard current.core != nil else { throw Failure.http(503, "Herdr Core is not running on the server. Start it there, then try again.") }
        if let agent = liveAgent(named: name, in: current) { return .running(agent, program: current.program(of: agent)) }
        do {
            let agent = try await start(name: name, template: template, model: model, task: nil, projects: projects.map(\.id), workspaceID: workspaceID, in: current)
            return .started(agent, program: current.program(of: agent))
        }
        // A bridge from before this route knew `warm` refuses the body itself (422), as a newer one refuses a
        // template that cannot start without its task.
        catch Failure.http(let code, _) where code == 400 || code == 422 { return .unavailable }
    }

    /// Ends this bot's agent when it was started ahead of time and nothing has been sent to it yet, so that another
    /// can start as the bot is set up now (another agent program or model). An agent that has had a task keeps
    /// running: it holds a conversation. Returns whether one was ended.
    func endUnused(name: String) async throws -> Bool {
        let current = try await workspace()
        guard let core = current.core, let agent = liveAgent(named: name, in: current), agent.warm == true else { return false }
        guard try await history(core: core, address: agent.address, createdMs: agent.createdMs).allSatisfy({ $0.kind != "task" }) else { return false }
        try await endIfIdle(agent, core: core, workspace: current, unusedOnly: true)
        return true
    }

    /// A first message must fit alongside the bot’s instructions and the app’s notes. Validate the byte budget
    /// before sending so the complete message reaches the agent.
    static let messageBytes = 8_000, instructionsBytes = 7_000, notesBytes = 6_700, taskBytes = 16_000

    struct TaskFile: Sendable {
        static let maxBytes = 8 * 1024 * 1024
        let name: String
        let mime: String
        let data: Data

        var uploadName: String {
            let cleaned = String(name.unicodeScalars.map { scalar in
                (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar))) ? Character(String(scalar)) : "_"
            }.prefix(170)).trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "attachment" : cleaned
        }

        static func validate(_ files: [Self]) throws {
            guard files.count <= 4, files.reduce(0, { $0 + $1.data.count }) <= maxBytes else {
                throw BackendError.unavailable("Attach up to four files totaling 8 MB per message.")
            }
        }
    }

    static func validateMessage(_ text: String, limit: Int = messageBytes) throws {
        if plain(text, bytes: Int.max).utf8.count > limit {
            throw BackendError.unavailable("This message exceeds the server’s \(limit)-byte limit. Shorten the message or send it as a text file.")
        }
    }

    func message(_ text: String, files: [TaskFile], to agent: Agent, core: String, turnReference: String? = nil) async throws -> Bool {
        guard !files.isEmpty else { return try await message(text, to: agent, expectedCore: core, turnReference: turnReference) }
        struct Delivery: Decodable { let queued: Bool? }
        let path = "/api/agents/\(agent.address)/\(agent.createdMs)/messages/with-files"
        var body = ["text": text, "expected_core": core]
        body["turn_reference"] = turnReference
        let delivery: Delivery = try await postFileTask(path, body, files: files)
        return delivery.queued == true
    }

    func steer(_ turn: Turn, text: String, files: [TaskFile]) async throws {
        guard let reference = turn.steerReference else { throw BackendError.unavailable("This session cannot receive a live follow-up.") }
        struct Receipt: Decodable { let delivered: Bool }
        let value = text.isEmpty && !files.isEmpty ? "Read the attached files." : text
        try Self.validateMessage(value)
        try TaskFile.validate(files)
        let body = ["text": Self.plain(value, bytes: Int.max), "expected_core": turn.core, "reference": reference]
        let path = "/api/agents/\(turn.address)/\(turn.createdMs)/steer"
        do {
            let receipt: Receipt
            if files.isEmpty { receipt = try await post(path, body) }
            else { receipt = try await postFileTask(path + "/with-files", body, files: files) }
            guard receipt.delivered else { throw Failure.unconfirmedDelivery }
        } catch Failure.http(let code, _) where code >= 500 { throw Failure.unconfirmedDelivery }
    }

    private func postFileTask<T: Decodable>(_ path: String, _ payload: [String: Any], files: [TaskFile]) async throws -> T {
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\n".utf8)
        body.append(try JSONSerialization.data(withJSONObject: payload))
        for file in files {
            let mime = file.mime.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil
                ? file.mime : "application/octet-stream"
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.uploadName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(file.data)
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = try request(path, method: "POST", body: body)
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try await send(upload)
    }

    /// Plain text as the bridge accepts it: no control characters except new lines and tabs, cut to `bytes` of UTF-8
    /// on a character boundary.
    static func plain(_ text: String, bytes: Int) -> String {
        var clean = String(String.UnicodeScalarView(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }))
        while clean.utf8.count > max(0, bytes) { clean.removeLast() }
        return clean
    }

    /// The first task of a new agent: the bot's standing instructions (with the app's notes after them), then the
    /// message. A running agent already has them.
    private static func firstTaskPrefix(_ instructions: String?) -> String {
        let rules = plain(instructions ?? "", bytes: instructionsBytes + notesBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.isEmpty ? "" : "Standing instructions for this whole conversation:\n\(rules)\n\nMy first message:\n"
    }

    static func firstMessageBudget(instructions: String?, hasFiles: Bool) -> Int {
        min(messageBytes, max(0, (hasFiles ? 12 * 1024 : taskBytes) - firstTaskPrefix(instructions).utf8.count))
    }

    static func firstTask(_ text: String, instructions: String?) -> String {
        firstTaskPrefix(instructions) + text
    }

    /// Types `text` into this bot's running agent, or starts one from `template` (on `model`, when the template takes
    /// one) with `instructions` and `text` as its first task.
    /// A bot that ran before keeps its saved profile, so its earlier sessions stay together in the workspace.
    /// `reminder` goes in front of a message to a running agent only: a new agent reads the same words in its instructions.
    /// `once` are notes a running agent must have read once (`marker` is a phrase only that note contains): each goes in
    /// front of the message while none of the agent's saved tasks carries its marker, so an agent that started before
    /// the note applied to its bot still learns it, and one that has read it is not told again.
    /// `changing` are notes that change (`lead` is how every version starts): one goes in front of the message while
    /// the newest saved task that has its lead does not carry this version, so the agent is told each change once.
    /// `projects`: what the bot may use on other servers. A new agent is launched with their ids. A running agent is
    /// given the list first when it changed since the agent last got it (`resync`, and `synced` hears that it went
    /// through), and is told the list as it is now in front of the message, once per change (`notes`' `revised`); a
    /// list that could not be set is not announced.
    /// An agent that was started ahead of time (`warm`) and is still starting gets the message all the same: the bridge
    /// keeps it and types it once the agent is ready (`Turn.queued`). `status` hears that the agent program is
    /// starting, as it does before a launch.
    func deliver(_ text: String, name: String, template: String?, model: String? = nil, instructions: String? = nil, reminder: String? = nil,
                 once: [(marker: String, note: String)] = [], changing: [(lead: String, note: String)] = [],
                 projects: [HerdrBotProject] = [], files: [TaskFile] = [], workspaceID: UUID? = nil, resync: Bool = false, synced: @Sendable () -> Void = {},
                 willSubmit: @Sendable () -> Void = {}, status: @Sendable (HerdrTurnStatus) -> Void = { _ in }) async throws -> Turn {
        try Self.validateMessage(text)
        try TaskFile.validate(files)
        var text = Self.plain(text, bytes: Int.max)
        let current = try await workspaceForDelivery(name: name, status: status)
        if !files.isEmpty, current.attachments != true {
            throw BackendError.unavailable("This server cannot receive attachments. Update its workspace and Herdr Core, then try again.")
        }
        guard let core = current.core else { throw Failure.http(503, "Herdr Core is not running on the server. Start it there, then try again.") }
        var active = liveAgent(named: name, in: current)
        let runtimeTemplate: Template?
        if let active { runtimeTemplate = current.templates.first { $0.name == active.template } }
        else { runtimeTemplate = current.launchTemplate(named: template) }
        var steerReference: String?
        var wireReference: String?
        var reservedBytes = 0
        if runtimeTemplate?.runtime?.harness?.lowercased() == "codex", current.codexTurnSteer == true {
            let reference = UUID().uuidString
            let marked = "[SwarmHub turn \(reference)]\n" + text
            // Keep the normal turn usable when it occupies the full first-message budget.
            if marked.utf8.count <= min(Self.messageBytes, Self.firstMessageBudget(instructions: instructions, hasFiles: !files.isEmpty)) {
                steerReference = reference
                if (current.bridge?.api ?? 0) >= 3 {
                    wireReference = reference
                    reservedBytes = marked.utf8.count - text.utf8.count
                } else {
                    text = marked
                }
            }
        }
        if active == nil, !files.isEmpty, current.launchAttachments != true {
            try Self.validateMessage(text, limit: Self.firstMessageBudget(instructions: instructions, hasFiles: true))
            let started = try await start(name: name, template: template, model: model, task: nil, projects: projects.map(\.id), workspaceID: workspaceID, in: current)
            if started.status?.state == "working" {
                active = try await waitForIdle(started, name: name, core: core, status: status).agent
            } else {
                active = started
            }
        }
        if let agent = active {
            if agent.status?.state == "blocked" { throw agent.promptFailure(program: current.program(of: agent)) }
            // Started ahead of time and not ready yet: the bridge keeps the message and types it when the agent is.
            if agent.isStarting { status(.starting(program: current.program(of: agent))) }
            let saved = try await history(core: core, address: agent.address, createdMs: agent.createdMs)
            let after = saved.map(\.id).max() ?? 0
            let afterTool = (try? await preview(core: core, address: agent.address, createdMs: agent.createdMs))?.tools.map(\.seq).max() ?? 0
            var applied = true
            if resync {
                do { try await setAgentProjects(projects.map(\.id), for: agent); synced() } catch { applied = false }
            }
            let tasks = saved.filter(\.reachedAgent).map(\.text)
            let notes = Self.notes(reminder: reminder, once: once, tasks: tasks, changing: changing,
                                   revised: applied ? [(HerdrProjectNote.lead, HerdrProjectNote.note(projects), projects.isEmpty)] : [])
            // An agent that was started ahead of time and has read nothing yet (the bridge says `warm` until a task
            // has reached it): this message is its first task, and the bridge adds nothing of the app's to it, so it
            // carries what a first task carries (the bot's instructions and the notes, which `instructions` holds),
            // whole. Any later message finds that task saved, also while the bridge still keeps it, and carries none
            // of it again; a task that was never typed does not count (`Item.reachedAgent`), so the next one
            // carries it all again.
            let firstMessage = (agent.warm == true || liveAgent(named: name, in: current) == nil) && tasks.isEmpty
            let body: String
            if firstMessage, !Self.firstTaskPrefix(instructions).isEmpty {
                try Self.validateMessage(text, limit: Self.firstMessageBudget(instructions: instructions, hasFiles: !files.isEmpty))
                body = Self.firstTask(text, instructions: instructions)
            } else {
                let budget = (files.isEmpty ? Self.taskBytes : 12 * 1024) - text.utf8.count - reservedBytes - 2
                let prefix = Self.plain(notes.joined(separator: "\n\n"), bytes: min(Self.instructionsBytes, budget))
                body = prefix.isEmpty ? text : prefix + "\n\n" + text
            }
            if !files.isEmpty { try Self.validateMessage(body, limit: 12 * 1024) }
            try Task.checkCancellation()
            willSubmit()
            let queued = try await message(body, files: files, to: agent, core: core, turnReference: wireReference)
            return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: after, launched: false, steerReference: steerReference, submittedText: body, afterTool: afterTool, program: current.program(of: agent), queued: queued)
        }
        status(.starting(program: Self.program(template: template, in: current)))
        try Self.validateMessage(text, limit: Self.firstMessageBudget(instructions: instructions, hasFiles: !files.isEmpty))
        let first = Self.firstTask(text, instructions: instructions)
        willSubmit()
        let agent = try await start(name: name, template: template, model: model, task: first, projects: projects.map(\.id), workspaceID: workspaceID, files: files, turnReference: wireReference, in: current)
        if resync { synced() }
        if agent.openCodeFirstTask == "uncertain" { throw Failure.unconfirmedDelivery }
        if agent.openCodeFirstTask == "not_sent" { throw Failure.notDelivered("OpenCode did not accept the first task.") }
        if agent.firstMessage?.sent == false { throw agent.promptFailure(program: current.program(of: agent)) }
        return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: 0, launched: true, steerReference: steerReference, submittedText: first, program: current.program(of: agent))
    }

    /// Starts this bot's agent from `template` (nil: the first the server can start), on `model` when the template
    /// takes one, with `task` as its first task, or with none (ahead of time, `launch`).
    /// A bot that ran before keeps its saved profile, so its earlier sessions stay together in the workspace.
    func start(name: String, template: String?, model: String?, task: String?, projects: [Int], workspaceID: UUID? = nil, files: [TaskFile] = [], turnReference: String? = nil, in current: Workspace) async throws -> Agent {
        guard let chosen = current.launchTemplate(named: template) else { throw Failure.noTemplate }
        let known = try await profiles().first { $0.runtimeName == name || Self.suffix(of: $0.runtimeName) == Self.suffix(of: name) }
        // A bot with no model of its own starts on the first one the server offers for the template (`defaultModel`):
        // the model the app shows for it. Only a template with no list leaves the choice to the agent program.
        var modelID = chosen.takesModel ? model.flatMap { $0.isEmpty ? nil : $0 } : nil
        if chosen.takesModel, modelID == nil || modelID == HerdrModelChoice.recommended {
            let offered = (try? await models(for: chosen)) ?? chosen.models ?? []
            modelID = modelID == HerdrModelChoice.recommended
                ? HerdrModelChoice.suggested(program: chosen.modelAgent ?? chosen.programName, offered: offered)?.id
                : Self.defaultModel(offered: offered)
        }
        return try await launch(name: known?.runtimeName ?? name, template: chosen.name, task: task, profileID: known?.id, modelID: modelID, projects: projects, workspaceID: current.botWorkspaces == true ? workspaceID : nil, files: files, expectedCore: current.core, turnReference: turnReference)
    }

    /// The server's name for the agent program a bot's next agent starts ("Codex"); nil when the server names none.
    static func program(template: String?, in workspace: Workspace) -> String? {
        workspace.launchTemplate(named: template)?.programName
    }

    /// What goes in front of a message to a running agent: `reminder` always, each of `once` only while no saved task
    /// has its marker, and each of `changing` while the newest saved task with its lead is not this version of it
    /// (the names of the other bots, which change). A note is never there twice.
    /// `revised` is a `changing` note about something the agent may never have had (its projects on other servers):
    /// with `onlyAfter` it goes out only when an earlier task has its lead, so an agent that never had any is not
    /// told that it has none.
    static func notes(reminder: String?, once: [(marker: String, note: String)], tasks: [String], changing: [(lead: String, note: String)] = [],
                      revised: [(lead: String, note: String, onlyAfter: Bool)] = []) -> [String] {
        var notes = reminder.map { [$0] } ?? []
        for item in once where !item.note.isEmpty && !notes.contains(item.note) && !tasks.contains(where: { $0.contains(item.marker) }) { notes.append(item.note) }
        for item in changing where !item.note.isEmpty && tasks.last(where: { $0.contains(item.lead) })?.contains(item.note) != true { notes.append(item.note) }
        for item in revised where !item.note.isEmpty {
            let last = tasks.last { $0.contains(item.lead) }
            if last?.contains(item.note) != true, !(item.onlyAfter && last == nil) { notes.append(item.note) }
        }
        return notes
    }

    /// Waits for the reply the agent's hook saves after `turn`. Meanwhile `status` hears what the turn is waiting for,
    /// as the agent reports it (`HerdrTurnStatus`),
    /// `tool` hears each tool call when it is first seen (`true`) and again when it has ended, `partial` hears the
    /// reply so far (Claude Code, Codex and OpenCode all publish one), and `live` hears the agent's helpers and
    /// whether the turn is on the event stream.
    /// The turn is followed on the bridge's event stream. A bridge without one, a bridge with all its streams taken,
    /// or a connection that keeps breaking leaves the turn to the polling routes, with everything seen so far kept,
    /// so no step is reported twice and no turn is lost (`HerdrTurnFollower` decides the same way for both).
    /// An agent that goes quiet without saving a reply (its hook was not trusted, or it stopped at a prompt) ends the
    /// wait; `quietLimit` outlasts the bridge's 30 s limit on that hook, which a busy disk on the server can use up.
    func reply(to turn: Turn, quietLimit: Duration = .seconds(45), status: @Sendable (HerdrTurnStatus) -> Void = { _ in },
               tool: @Sendable (ToolCall, _ isNew: Bool) -> Void = { _, _ in }, partial: @Sendable (String) -> Void = { _ in },
               live: @Sendable (LiveNote) -> Void = { _ in }) async throws -> String {
        try await replyWithActivity(to: turn, quietLimit: quietLimit, status: status, tool: tool, partial: partial, live: live).text
    }

    func replyWithActivity(to turn: Turn, quietLimit: Duration = .seconds(45), status: @Sendable (HerdrTurnStatus) -> Void,
                           tool: @Sendable (ToolCall, Bool) -> Void, partial: @Sendable (String) -> Void,
                           live: @Sendable (LiveNote) -> Void, published: @Sendable (HerdrPublishedResult) -> Void = { _ in }) async throws -> (text: String, tools: Int, ids: [Int], model: (String, RunSummary.ModelSource)?) {
        var follower = HerdrTurnFollower(after: turn.after, afterTool: turn.afterTool, quietLimit: quietLimit, program: turn.program, starting: turn.starting)
        func emit(_ steps: [HerdrTurnFollower.Step]) {
            for step in steps {
                switch step {
                case .status(let now): status(now)
                case .tool(let call, let isNew): tool(call, isNew)
                case .partial(let text): partial(text)
                case .published(let result): published(result)
                }
            }
        }
        defer { live(.following(false)) }
        if following == .stream, let reply = try await streamedReply(to: turn, follower: &follower, emit: emit, live: live) { return (reply, follower.toolCount, follower.replyIDs, follower.replyModel) }
        live(.following(false))
        let reply = try await polledReply(to: turn, follower: &follower, emit: emit)
        return (reply, follower.toolCount, follower.replyIDs, follower.replyModel)
    }

    /// What a turn tells its bot beside the reply: the agent's helpers as the stream reports them, and whether the
    /// stream is delivering (so nothing else needs to ask the bridge for them meanwhile).
    enum LiveNote: Sendable, Equatable { case helpers(Helpers?), following(Bool) }

    /// The turn by polling: the saved rows and the reply so far every `pollInterval`, the agent every `agentCheckInterval`.
    func polledReply(to turn: Turn, follower: inout HerdrTurnFollower, emit: ([HerdrTurnFollower.Step]) -> Void) async throws -> String {
        let clock = ContinuousClock()
        var nextAgentCheck = clock.now
        var retryUntil: ContinuousClock.Instant?
        var retryDelay = pollInterval
        while true {
            do {
                try Task.checkCancellation()
                follower.take(rows: try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs))
                // The preview is a convenience: a failed read never ends the turn.
                if let seen = try? await preview(core: turn.core, address: turn.address, createdMs: turn.createdMs) { follower.take(tools: seen.tools); follower.take(draftText: seen.draft) }
                // A message steered into the turn is one more task. The agent may answer it within the same reply, or queue
                // it and answer it right after: then a second reply follows, and the turn's text is both.
                let saved = follower.judgeSaved(now: clock.now)
                emit(follower.drain())
                if case .reply(let text) = saved { return text }
                if case .failed(let failure) = saved { throw failure }
                if follower.wantsAgentNow { nextAgentCheck = clock.now; follower.wantsAgentNow = false }
                if clock.now >= nextAgentCheck {
                    nextAgentCheck = clock.now + agentCheckInterval
                    let agent = try await workspace().agents.first { $0.address == turn.address && $0.createdMs == turn.createdMs }
                    guard let agent, agent.isLive else {
                        // One more read: the hook may have saved the reply as the session closed.
                        follower.take(rows: try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs))
                        emit(follower.drain())
                        return try follower.ended()
                    }
                    follower.take(agent: agent)
                    try await follower.checkRejectedLogin(using: self, now: clock.now)
                    let verdict = follower.judgeAgent(now: clock.now)
                    emit(follower.drain())
                    if case .failed(let failure) = verdict { throw failure }
                }
                retryUntil = nil
                retryDelay = pollInterval
                try await Task.sleep(for: pollInterval)
            } catch where Self.canResumeRead(after: error) {
                try Task.checkCancellation()
                let deadline = retryUntil ?? clock.now + reconnectLimit
                guard clock.now < deadline else { throw error }
                retryUntil = deadline
                follower.connectionLost()
                emit(follower.drain())
                try await clock.sleep(until: min(clock.now + retryDelay, deadline))
                retryDelay = min(retryDelay * 2, .seconds(3))
            }
        }
    }

    private static func canResumeRead(after error: Error) -> Bool {
        if case Failure.http(let code, _) = error { return TransientNetwork.gatewayStatuses.contains(code) }
        if let ssh = error as? HerdrTunnel.Failure {
            switch ssh {
            case .timedOut: return true
            case .ended(let reason):
                return ["Connection refused", "Connection timed out", "Operation timed out", "Connection reset",
                        "No route to host", "Network is unreachable", "Could not resolve hostname"].contains { reason.localizedCaseInsensitiveContains($0) }
            case .notSSH: return false
            }
        }
        return TransientNetwork.isTransient(error)
    }

    // MARK: Transport

    /// `timeout`: how long the bridge may take to answer. Most routes answer at once; one that runs a program on the
    /// server (`HerdrSkills.swift`) says how long that may take, and the client waits a little longer.
    func get<T: Decodable>(_ path: String, timeout: TimeInterval = Self.requestSeconds) async throws -> T { try await send(request(path, method: "GET", body: nil, timeout: timeout)) }

    func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = Self.requestSeconds) async throws -> T {
        try await send(request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body), timeout: timeout))
    }

    static let requestSeconds: TimeInterval = 100
    /// "0.7.0 (34)": the running app, as its bundle names it.
    static let appIdentity = HerdrCompatibility.appIdentity(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                                                            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String)

    func request(_ path: String, method: String, body: Data?, timeout: TimeInterval = Self.requestSeconds) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path), let host = baseURL.host else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The bridge compares Origin with Host on every POST (its browser page sends both).
        let port = baseURL.port.map { ":\($0)" } ?? ""
        let authority = forwardedHost ?? host + port
        if let forwardedHost, forwardedHost != host + port {
            // Older bridges expect this exact authority. Newer ones also handle URLSession rewriting Host.
            request.setValue(forwardedHost, forHTTPHeaderField: "Host")
            request.setValue("1", forHTTPHeaderField: "X-SwarmHub-SSH-Forward")
        }
        request.setValue("\(baseURL.scheme ?? "http")://\(authority)", forHTTPHeaderField: "Origin")
        // Which app asks, and the API level it is written for (`HerdrCompatibility`).
        request.setValue(Self.appIdentity, forHTTPHeaderField: HerdrCompatibility.appHeader)
        request.setValue(String(HerdrCompatibility.level), forHTTPHeaderField: HerdrCompatibility.levelHeader)
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func connectedBaseURL() async throws -> URL {
        guard let prepare else { return baseURL }
        let port = try await prepare()
        return try url(baseURL, onPort: port)
    }

    func prepared(_ request: URLRequest) async throws -> URLRequest {
        guard let prepare, let originalURL = request.url else { return request }
        let port = try await prepare()
        guard originalURL.port != port else { return request }
        var next = request
        next.url = try url(originalURL, onPort: port)
        if let forwardedHost {
            next.setValue(forwardedHost, forHTTPHeaderField: "Host")
            next.setValue("1", forHTTPHeaderField: "X-SwarmHub-SSH-Forward")
        }
        return next
    }

    private func url(_ url: URL, onPort port: Int) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Failure.invalidURL }
        parts.port = port
        guard let connected = parts.url else { throw Failure.invalidURL }
        return connected
    }

    /// A request's body and status as they came, for routes whose refusals carry more than a sentence (`HerdrProjects.swift`).
    func raw(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let preparedRequest = try await prepared(request)
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: preparedRequest)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct Problem: Decodable { let error: String }

    /// What a status other than 2xx means, with the bridge's own sentence when its body carries one.
    static func failure(status code: Int, body: Data) -> Failure {
        if code == 401 { return .unauthorized }
        if code == 403 { return .refusedHost }
        return .http(code, (try? JSONDecoder().decode(Problem.self, from: body))?.error ?? "The Herdr workspace answered HTTP \(code).")
    }

    func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, status) = try await raw(request)
        guard (200..<300).contains(status) else { throw Self.failure(status: status, body: data) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

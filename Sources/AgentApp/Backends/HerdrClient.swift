import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The SwarmHub bridge that runs beside Herdr Core (`HerdrWorkspace/`, `swarmhub-herdr`), over its local HTTP API.
/// Herdr Core runs agent programs in terminals; the bridge launches them from Core's templates, types tasks into them
/// and saves each finished reply through the agent's own Stop hook. This client only talks to the bridge.
///
/// The bridge listens on loopback and refuses any request whose `Host` is not `127.0.0.1:<port>` or
/// `localhost:<port>`; a `POST` must also carry the matching `Origin`. From another machine, forward the same port
/// (`ssh -L 8787:127.0.0.1:8787 server`). Foundation only, so it also builds on Linux for the bridge's own checks.
struct HerdrClient: Sendable {
    struct Template: Decodable, Sendable, Equatable {
        /// On a template: its agent program. On a saved session (`Profile.Session`): also the model the agent was
        /// started on, `modelId` and its `model` label, both nil when it was started without one.
        struct Runtime: Decodable, Sendable, Equatable { let harness: String?; let provider: String?; let model: String?; var modelId: String? = nil }
        /// A model the template offers by name (the bridge's `runtime-catalog.json`).
        struct Model: Decodable, Sendable, Equatable { let id: String; let label: String? }
        let name: String; let description: String?; let error: String?; let runtime: Runtime?
        /// Set when the template can start its agent on a chosen model; `discoverModels` when the agent program can list them.
        var modelAgent: String? = nil; var models: [Model]? = nil; var discoverModels: Bool? = nil
        var takesModel: Bool { modelAgent != nil }
        /// "Claude Code · swarmhub-claude": the agent program first, since that is what people choose by.
        var label: String { runtime?.harness.map { "\($0) · \(name)" } ?? name }
    }

    struct Agent: Decodable, Sendable, Equatable {
        struct Status: Decodable, Sendable, Equatable { let state: String? }
        /// Core types the first task only once the agent reports that it is ready; a start-up prompt leaves it unsent.
        struct FirstMessage: Decodable, Sendable, Equatable { let sent: Bool? }
        let address: String; let name: String; let state: String; let createdMs: UInt64; let template: String?; let status: Status?
        var firstMessage: FirstMessage? = nil
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
        var isStarting: Bool { isLive && ready == false }
    }

    struct Workspace: Decodable, Sendable {
        let core: String?; let version: String?; let agents: [Agent]; let templates: [Template]
        /// The server's name for the agent program `agent` runs ("Codex"); nil when its template names none.
        func program(of agent: Agent) -> String? { templates.first { $0.name == agent.template }?.runtime?.harness }
    }

    /// A bot's saved profile on the bridge, with its newest sessions and what each was launched with.
    struct Profile: Decodable, Sendable {
        struct Session: Decodable, Sendable, Equatable { let address: String; let createdMs: UInt64; var runtime: Template.Runtime? = nil }
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
        enum CodingKeys: CodingKey { case id, kind, text, state, detail }
        init(id: Int, kind: String, text: String, state: String? = nil, detail: String? = nil) { self.id = id; self.kind = kind; self.text = text; self.state = state; self.detail = detail }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
            state = try? c.decodeIfPresent(String.self, forKey: .state); detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        }
        /// A task that was never typed into the agent.
        var wasNotSent: Bool { kind == "task" && state == "not_sent" }
        /// A task the agent has read or will read: one that was never typed into it taught it nothing.
        var reachedAgent: Bool { kind == "task" && !wasNotSent }
    }

    /// A tool call the agent's hooks reported (`tool_activity` in the bridge): `seq` only grows; `detail` is the
    /// command, file, search or address in one line.
    struct ToolCall: Decodable, Sendable, Equatable { let seq: UInt64; let tool: String; let detail: String?; let finished: Bool; let failed: Bool }

    /// A task on its way: the session it went to and the last saved row and tool call before it, so its reply and
    /// its tool calls are the ones after those.
    struct Turn: Sendable, Equatable {
        let core: String; let address: String; let createdMs: UInt64; let after: Int; let launched: Bool
        var afterTool: UInt64 = 0
        /// The server's name for the agent program that answers, for the status lines; nil when it gives none.
        var program: String? = nil
        /// The bridge keeps the message for an agent that is still starting, and types it when the agent is ready.
        var queued = false
        /// The agent program is still starting when the turn begins: it was launched for it, or is not ready yet.
        var starting: Bool { launched || queued }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL, unauthorized, refusedHost, http(Int, String), noTemplate, ended, silent, waitingAtPrompt, notDelivered(String?)
        var errorDescription: String? {
            switch self {
            case .invalidURL: "The Herdr workspace address is invalid. Use http://127.0.0.1:8787 or the port you forwarded."
            case .unauthorized: "The Herdr workspace did not accept the access key. Paste it again in Settings."
            case .refusedHost: "The Herdr workspace only answers on 127.0.0.1 or localhost with its own port. Forward that same port to this Mac."
            case .http(_, let message): message
            case .noTemplate: "Choose an agent runtime for this bot. Herdr Core has no template the workspace can start."
            case .ended: "The agent's session ended before it replied. Send the message again to start a new one."
            case .silent: "The agent finished without a saved reply. Open the Herdr workspace to see its terminal."
            // The server's own sentence says why and what to look at; without one, the same in the app's words.
            case .notDelivered(let why): why.map { "\($0) Then send the message again." } ?? "The agent did not become ready, so your message was not delivered. Open the Herdr workspace to see its terminal, then send the message again."
            case .waitingAtPrompt: "The agent started but is showing a prompt, so it has not taken your message. Answer the prompt in the Herdr workspace (Take over), then send the message again."
            }
        }
    }

    let baseURL: URL
    let token: String
    var session: URLSession = .shared
    /// Between two reads of a session while waiting for its reply, and between two looks at the agent's status.
    var pollInterval: Duration = .milliseconds(400)
    var agentCheckInterval: Duration = .seconds(2)
    /// Runs before every request. A server reached over SSH opens its port forward here when it is not up
    /// (`HerdrTunnels.ensure`), so each caller gets a working connection without knowing how the server is reached.
    var prepare: (@Sendable () async throws -> Void)? = nil
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

    func workspace() async throws -> Workspace { try await get("/api/workspace") }
    func profiles() async throws -> [Profile] { try await get("/api/profiles") }

    func history(core: String, address: String, createdMs: UInt64) async throws -> [Item] {
        struct Page: Decodable { let items: [Item] }
        let page: Page = try await get("/api/history/\(core)/\(address)/\(createdMs)")
        return page.items
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
    func launch(name: String, template: String, task: String?, profileID: Int?, modelID: String? = nil, projects: [Int] = []) async throws -> Agent {
        var body: [String: Any] = ["name": name, "template": template]
        if let task { body["task"] = task } else { body["warm"] = true }
        if let profileID { body["profile_id"] = profileID }
        if let modelID { body["model_id"] = modelID }
        if !projects.isEmpty { body["projects"] = projects }
        return try await post("/api/agents", body)
    }

    /// The models a template can start on: its named ones, and what the agent program lists when it can.
    func models(for template: Template) async throws -> [Template.Model] {
        var found = template.models ?? []
        if template.discoverModels == true {
            struct Listed: Decodable { let models: [Template.Model] }
            let listed: Listed = try await post("/api/runtime-models/\(template.name)", [:])
            found += listed.models.filter { model in !found.contains { $0.id == model.id } }
        }
        return found
    }

    /// The model a bot without one of its own starts on: the first the server offers for its template. The server's
    /// list decides which that is, because the app itself names no model; nil when the server offers none.
    static func defaultModel(offered: [Template.Model]) -> String? { offered.first?.id }

    /// Closes the agent's session; its saved conversation stays in the workspace.
    func end(_ agent: Agent) async throws {
        struct Ended: Decodable {}
        let _: Ended = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/end", [:])
    }

    /// Types `text` into the agent. True when the bridge kept it instead, for an agent that was started ahead of
    /// time and is not ready yet: it is saved there, typed as soon as the agent is ready, and never typed twice.
    @discardableResult func message(_ text: String, to agent: Agent) async throws -> Bool {
        struct Delivery: Decodable { let status: String?; let queued: Bool? }
        let delivery: Delivery = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/messages", ["text": text])
        return delivery.queued == true
    }

    func interrupt(_ agent: Agent) async throws {
        struct Outcome: Decodable {}
        let _: Outcome = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/interrupt", [:])
    }

    // MARK: A turn

    /// The live agent for this bot: the same name, or the same id suffix after a rename. Never a helper, whose
    /// terminal is named by the agent that started it.
    func liveAgent(named name: String, in workspace: Workspace) -> Agent? {
        let live = workspace.agents.filter { $0.isLive && $0.parent == nil }
        return live.first { $0.name == name } ?? live.first { Self.suffix(of: $0.name) == Self.suffix(of: name) }
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
    func warm(name: String, template: String?, model: String? = nil, projects: [HerdrBotProject] = []) async throws -> Warmed {
        let current = try await workspace()
        guard current.core != nil else { throw Failure.http(503, "Herdr Core is not running on the workspace's machine.") }
        if let agent = liveAgent(named: name, in: current) { return .running(agent, program: current.program(of: agent)) }
        do {
            let agent = try await start(name: name, template: template, model: model, task: nil, projects: projects.map(\.id), in: current)
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
        try await end(agent)
        return true
    }

    /// The bridge takes up to 16 KB of plain text per task: the message and the bot's own instructions each get
    /// under half. The app's notes (`notesBytes`) come on top of the instructions when an agent starts; a first message
    /// that would not fit beside all of it is the part that is cut, never the bot's instructions.
    static let messageBytes = 8_000, instructionsBytes = 7_000, notesBytes = 4_600, taskBytes = 16_000

    /// Plain text as the bridge accepts it: no control characters except new lines and tabs, cut to `bytes` of UTF-8
    /// on a character boundary.
    static func plain(_ text: String, bytes: Int) -> String {
        var clean = String(String.UnicodeScalarView(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }))
        while clean.utf8.count > bytes { clean.removeLast() }
        return clean
    }

    /// The first task of a new agent: the bot's standing instructions (with the app's notes after them), then the
    /// message. A running agent already has them.
    static func firstTask(_ text: String, instructions: String?) -> String {
        let rules = plain(instructions ?? "", bytes: instructionsBytes + notesBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rules.isEmpty else { return text }
        let lead = "Standing instructions for this whole conversation:\n\(rules)\n\nMy first message:\n"
        return lead + plain(text, bytes: max(0, taskBytes - lead.utf8.count))
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
                 projects: [HerdrBotProject] = [], resync: Bool = false, synced: @Sendable () -> Void = {},
                 status: @Sendable (HerdrTurnStatus) -> Void = { _ in }) async throws -> Turn {
        let text = Self.plain(text, bytes: Self.messageBytes)
        let current = try await workspace()
        guard let core = current.core else { throw Failure.http(503, "Herdr Core is not running on the workspace's machine.") }
        if let agent = liveAgent(named: name, in: current) {
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
            let first = agent.warm == true && tasks.isEmpty ? Self.firstTask(text, instructions: instructions) : text
            let body = first != text ? first
                : (notes.isEmpty ? text : Self.plain(notes.joined(separator: "\n\n"), bytes: Self.instructionsBytes) + "\n\n" + text)
            let queued = try await message(body, to: agent)
            return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: after, launched: false, afterTool: afterTool, program: current.program(of: agent), queued: queued)
        }
        status(.starting(program: Self.program(template: template, in: current)))
        let agent = try await start(name: name, template: template, model: model, task: Self.firstTask(text, instructions: instructions), projects: projects.map(\.id), in: current)
        if resync { synced() }
        if agent.firstMessage?.sent == false { throw Failure.waitingAtPrompt }
        return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: 0, launched: true, program: current.program(of: agent))
    }

    /// Starts this bot's agent from `template` (nil: the first the server can start), on `model` when the template
    /// takes one, with `task` as its first task, or with none (ahead of time, `launch`).
    /// A bot that ran before keeps its saved profile, so its earlier sessions stay together in the workspace.
    func start(name: String, template: String?, model: String?, task: String?, projects: [Int], in current: Workspace) async throws -> Agent {
        let usable = current.templates.filter { $0.error == nil }
        guard let chosen = usable.first(where: { $0.name == template }) ?? (template == nil ? usable.first : nil) else { throw Failure.noTemplate }
        let known = try await profiles().first { $0.runtimeName == name || Self.suffix(of: $0.runtimeName) == Self.suffix(of: name) }
        // A bot with no model of its own starts on the first one the server offers for the template (`defaultModel`):
        // the model the app shows for it. Only a template with no list leaves the choice to the agent program.
        var modelID = chosen.takesModel ? model.flatMap { $0.isEmpty ? nil : $0 } : nil
        if modelID == nil, chosen.takesModel { modelID = Self.defaultModel(offered: (try? await models(for: chosen)) ?? chosen.models ?? []) }
        return try await launch(name: known?.runtimeName ?? name, template: chosen.name, task: task, profileID: known?.id, modelID: modelID, projects: projects)
    }

    /// The server's name for the agent program a bot's next agent starts ("Codex"); nil when the server names none.
    static func program(template: String?, in workspace: Workspace) -> String? {
        let usable = workspace.templates.filter { $0.error == nil }
        return (usable.first { $0.name == template } ?? (template == nil ? usable.first : nil))?.runtime?.harness
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
        var follower = HerdrTurnFollower(after: turn.after, afterTool: turn.afterTool, quietLimit: quietLimit, program: turn.program, starting: turn.starting)
        func emit(_ steps: [HerdrTurnFollower.Step]) {
            for step in steps {
                switch step {
                case .status(let now): status(now)
                case .tool(let call, let isNew): tool(call, isNew)
                case .partial(let text): partial(text)
                }
            }
        }
        defer { live(.following(false)) }
        if following == .stream, let reply = try await streamedReply(to: turn, follower: &follower, emit: emit, live: live) { return reply }
        live(.following(false))
        return try await polledReply(to: turn, follower: &follower, emit: emit)
    }

    /// What a turn tells its bot beside the reply: the agent's helpers as the stream reports them, and whether the
    /// stream is delivering (so nothing else needs to ask the bridge for them meanwhile).
    enum LiveNote: Sendable, Equatable { case helpers(Helpers?), following(Bool) }

    /// The turn by polling: the saved rows and the reply so far every `pollInterval`, the agent every `agentCheckInterval`.
    func polledReply(to turn: Turn, follower: inout HerdrTurnFollower, emit: ([HerdrTurnFollower.Step]) -> Void) async throws -> String {
        let clock = ContinuousClock()
        var nextAgentCheck = clock.now
        while true {
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
                    return try follower.ended()
                }
                follower.take(agent: agent)
                let verdict = follower.judgeAgent(now: clock.now)
                emit(follower.drain())
                if case .failed(let failure) = verdict { throw failure }
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: Transport

    /// `timeout`: how long the bridge may take to answer. Most routes answer at once; one that runs a program on the
    /// server (`HerdrSkills.swift`) says how long that may take, and the client waits a little longer.
    func get<T: Decodable>(_ path: String, timeout: TimeInterval = Self.requestSeconds) async throws -> T { try await send(request(path, method: "GET", body: nil, timeout: timeout)) }

    func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = Self.requestSeconds) async throws -> T {
        try await send(request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body), timeout: timeout))
    }

    static let requestSeconds: TimeInterval = 100

    func request(_ path: String, method: String, body: Data?, timeout: TimeInterval = Self.requestSeconds) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path), let host = baseURL.host else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The bridge compares Origin with Host on every POST (its browser page sends both).
        let port = baseURL.port.map { ":\($0)" } ?? ""
        request.setValue("\(baseURL.scheme ?? "http")://\(host)\(port)", forHTTPHeaderField: "Origin")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// A request's body and status as they came, for routes whose refusals carry more than a sentence (`HerdrProjects.swift`).
    func raw(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        try await prepare?()
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct Problem: Decodable { let error: String }

    /// What a status other than 2xx means, with the bridge's own sentence when its body carries one.
    static func failure(status code: Int, body: Data) -> Failure {
        if code == 401 { return .unauthorized }
        if code == 403 { return .refusedHost }
        return .http(code, (try? JSONDecoder().decode(Problem.self, from: body))?.error ?? "The Herdr workspace answered HTTP \(code).")
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        try await prepare?()
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.failure(status: code, body: data) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

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
        var isLive: Bool { state == "live" }
        var ref: AgentRef { AgentRef(address: address, createdMs: createdMs) }
    }

    struct Workspace: Decodable, Sendable { let core: String?; let version: String?; let agents: [Agent]; let templates: [Template] }

    /// A bot's saved profile on the bridge, with its newest sessions and what each was launched with.
    struct Profile: Decodable, Sendable {
        struct Session: Decodable, Sendable, Equatable { let address: String; let createdMs: UInt64; var runtime: Template.Runtime? = nil }
        let id: Int; let runtimeName: String
        var sessions: [Session]? = nil
    }

    /// One saved row of a session: `task` (what was sent) or `reply` (what the agent's hook saved).
    /// Other kinds (files, snapshots) carry no text; they decode with an empty one and are skipped.
    struct Item: Decodable, Sendable, Equatable {
        let id: Int; let kind: String; let text: String
        enum CodingKeys: CodingKey { case id, kind, text }
        init(id: Int, kind: String, text: String) { self.id = id; self.kind = kind; self.text = text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        }
    }

    /// A tool call the agent's hooks reported (`tool_activity` in the bridge): `seq` only grows; `detail` is the
    /// command, file, search or address in one line.
    struct ToolCall: Decodable, Sendable, Equatable { let seq: UInt64; let tool: String; let detail: String?; let finished: Bool; let failed: Bool }

    /// A task on its way: the session it went to and the last saved row and tool call before it, so its reply and
    /// its tool calls are the ones after those.
    struct Turn: Sendable, Equatable {
        let core: String; let address: String; let createdMs: UInt64; let after: Int; let launched: Bool
        var afterTool: UInt64 = 0
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL, unauthorized, refusedHost, http(Int, String), noTemplate, ended, silent, waitingAtPrompt
        var errorDescription: String? {
            switch self {
            case .invalidURL: "The Herdr workspace address is invalid. Use http://127.0.0.1:8787 or the port you forwarded."
            case .unauthorized: "The Herdr workspace did not accept the access token. Paste it again in Settings."
            case .refusedHost: "The Herdr workspace only answers on 127.0.0.1 or localhost with its own port. Forward that same port to this Mac."
            case .http(_, let message): message
            case .noTemplate: "Choose an agent runtime for this bot. Herdr Core has no template the workspace can start."
            case .ended: "The agent's session ended before it replied. Send the message again to start a new one."
            case .silent: "The agent finished without a saved reply. Open the Herdr workspace to see its terminal."
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

    func launch(name: String, template: String, task: String, profileID: Int?, modelID: String? = nil) async throws -> Agent {
        var body: [String: Any] = ["name": name, "template": template, "task": task]
        if let profileID { body["profile_id"] = profileID }
        if let modelID { body["model_id"] = modelID }
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

    func message(_ text: String, to agent: Agent) async throws {
        struct Delivery: Decodable { let status: String? }
        let _: Delivery = try await post("/api/agents/\(agent.address)/\(agent.createdMs)/messages", ["text": text])
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

    /// The bridge takes up to 16 KB of plain text per task: the message and the bot's own instructions each get
    /// under half. The app's notes (`notesBytes`) come on top of the instructions when an agent starts; a first message
    /// that would not fit beside all of it is the part that is cut, never the bot's instructions.
    static let messageBytes = 8_000, instructionsBytes = 7_000, notesBytes = 3_600, taskBytes = 16_000

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
    func deliver(_ text: String, name: String, template: String?, model: String? = nil, instructions: String? = nil, reminder: String? = nil,
                 once: [(marker: String, note: String)] = []) async throws -> Turn {
        let text = Self.plain(text, bytes: Self.messageBytes)
        let current = try await workspace()
        guard let core = current.core else { throw Failure.http(503, "Herdr Core is not running on the workspace's machine.") }
        if let agent = liveAgent(named: name, in: current) {
            let saved = try await history(core: core, address: agent.address, createdMs: agent.createdMs)
            let after = saved.map(\.id).max() ?? 0
            let afterTool = (try? await preview(core: core, address: agent.address, createdMs: agent.createdMs))?.tools.map(\.seq).max() ?? 0
            let notes = Self.notes(reminder: reminder, once: once, tasks: saved.filter { $0.kind == "task" }.map(\.text))
            try await message(notes.isEmpty ? text : Self.plain(notes.joined(separator: "\n\n"), bytes: Self.instructionsBytes) + "\n\n" + text, to: agent)
            return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: after, launched: false, afterTool: afterTool)
        }
        let usable = current.templates.filter { $0.error == nil }
        guard let chosen = usable.first(where: { $0.name == template }) ?? (template == nil ? usable.first : nil) else { throw Failure.noTemplate }
        let known = try await profiles().first { $0.runtimeName == name || Self.suffix(of: $0.runtimeName) == Self.suffix(of: name) }
        // A bot with no model of its own starts on the first one the server offers for the template (`defaultModel`):
        // the model the app shows for it. Only a template with no list leaves the choice to the agent program.
        var modelID = chosen.takesModel ? model.flatMap { $0.isEmpty ? nil : $0 } : nil
        if modelID == nil, chosen.takesModel { modelID = Self.defaultModel(offered: (try? await models(for: chosen)) ?? chosen.models ?? []) }
        let agent = try await launch(name: known?.runtimeName ?? name, template: chosen.name, task: Self.firstTask(text, instructions: instructions),
                                     profileID: known?.id, modelID: modelID)
        if agent.firstMessage?.sent == false { throw Failure.waitingAtPrompt }
        return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: 0, launched: true)
    }

    /// What goes in front of a message to a running agent: `reminder` always, each of `once` only while no saved task
    /// has its marker. A note is never there twice.
    static func notes(reminder: String?, once: [(marker: String, note: String)], tasks: [String]) -> [String] {
        var notes = reminder.map { [$0] } ?? []
        for item in once where !item.note.isEmpty && !notes.contains(item.note) && !tasks.contains(where: { $0.contains(item.marker) }) { notes.append(item.note) }
        return notes
    }

    /// Waits for the reply the agent's hook saves after `turn`. Meanwhile `status` hears what the agent reports,
    /// `tool` hears each tool call when it is first seen (`true`) and again when it has ended, and `partial` hears the reply so far for
    /// agents whose template publishes one (Claude Code with `--workspace-preview`, OpenCode). Codex has no hook for
    /// unfinished text, so its reply arrives whole.
    /// An agent that goes quiet without saving a reply (its hook was not trusted, or it stopped at a prompt) ends the
    /// wait; `quietLimit` outlasts the bridge's 30 s limit on that hook, which a busy disk on the server can use up.
    func reply(to turn: Turn, quietLimit: Duration = .seconds(45), status: @Sendable (String) -> Void = { _ in },
               tool: @Sendable (ToolCall, _ isNew: Bool) -> Void = { _, _ in }, partial: @Sendable (String) -> Void = { _ in }) async throws -> String {
        let clock = ContinuousClock()
        var quietSince: ContinuousClock.Instant?, nextAgentCheck = clock.now
        var lastStatus = "", lastDraft = ""
        /// After a reply with a steered message still unanswered: how long the agent may stay idle before the turn is over.
        let settle = Duration.seconds(5)
        var repliesSeen = 0, settleSince: ContinuousClock.Instant?
        /// seq → whether its end was reported too.
        var reported: [UInt64: Bool] = [:]
        func report(_ calls: [ToolCall]) {
            for call in calls where call.seq > turn.afterTool && reported[call.seq] != true {
                if reported[call.seq] == nil { tool(call, true) } else if call.finished { tool(call, false) } else { continue }
                reported[call.seq] = call.finished
            }
        }
        while true {
            try Task.checkCancellation()
            let items = try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs)
            // The preview is a convenience: a failed read never ends the turn.
            let seen = try? await preview(core: turn.core, address: turn.address, createdMs: turn.createdMs)
            report(seen?.tools ?? [])
            // A message steered into the turn is one more task. The agent may answer it within the same reply, or queue
            // it and answer it right after: then a second reply follows, and the turn's text is both.
            let replies = items.filter { $0.kind == "reply" && $0.id > turn.after }
            let tasks = items.filter { $0.kind == "task" && $0.id > turn.after }.count
            let answered = replies.map(\.text).joined(separator: "\n\n")
            if !replies.isEmpty {
                if replies.count >= max(tasks, 1) { return answered }
                if replies.count != repliesSeen { repliesSeen = replies.count; settleSince = clock.now; partial(answered); nextAgentCheck = clock.now }
                if let since = settleSince, clock.now - since >= settle { return answered }
            }
            if let text = seen?.draft, !text.isEmpty, text != lastDraft { partial(answered.isEmpty ? text : answered + "\n\n" + text); lastDraft = text }
            if clock.now >= nextAgentCheck {
                nextAgentCheck = clock.now + agentCheckInterval
                let agent = try await workspace().agents.first { $0.address == turn.address && $0.createdMs == turn.createdMs }
                guard let agent, agent.isLive else {
                    // One more read: the hook may have saved the reply as the session closed.
                    let final = try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs)
                    if let reply = final.first(where: { $0.kind == "reply" && $0.id > turn.after }) { return reply.text }
                    throw Failure.ended
                }
                let state = agent.status?.state ?? ""
                // Working again after a reply: the queued message is being answered, so keep waiting for it.
                if state == "working", settleSince != nil { settleSince = clock.now }
                let line = Self.statusLine(state)
                if line != lastStatus { status(line); lastStatus = line }
                // "done" or "idle" with nothing saved: the hook may still be writing; stop waiting once it cannot be.
                if state == "done" || state == "idle" {
                    let since = quietSince ?? clock.now
                    quietSince = since
                    if clock.now - since >= quietLimit { throw Failure.silent }
                } else { quietSince = nil }
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    static func statusLine(_ state: String) -> String {
        switch state {
        case "working": "Working in Herdr"
        case "blocked": "Waiting for you in the agent's terminal"
        case "error": "The agent reported an error"
        case "done", "idle": "Finishing"
        default: "Starting in Herdr"
        }
    }

    // MARK: Transport

    func get<T: Decodable>(_ path: String) async throws -> T { try await send(request(path, method: "GET", body: nil)) }

    func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        try await send(request(path, method: "POST", body: try JSONSerialization.data(withJSONObject: body)))
    }

    private func request(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path), let host = baseURL.host else { throw Failure.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 100)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The bridge compares Origin with Host on every POST (its browser page sends both).
        let port = baseURL.port.map { ":\($0)" } ?? ""
        request.setValue("\(baseURL.scheme ?? "http")://\(host)\(port)", forHTTPHeaderField: "Origin")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private struct Problem: Decodable { let error: String }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        try await prepare?()
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw Failure.unauthorized }
            if code == 403 { throw Failure.refusedHost }
            let message = (try? JSONDecoder().decode(Problem.self, from: data))?.error
            throw Failure.http(code, message ?? "The Herdr workspace answered HTTP \(code).")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}

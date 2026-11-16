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
        struct Runtime: Decodable, Sendable, Equatable { let harness: String?; let provider: String?; let model: String? }
        let name: String; let description: String?; let error: String?; let runtime: Runtime?
        /// "Claude Code · swarmhub-claude": the agent program first, since that is what people choose by.
        var label: String { runtime?.harness.map { "\($0) · \(name)" } ?? name }
    }

    struct Agent: Decodable, Sendable, Equatable {
        struct Status: Decodable, Sendable, Equatable { let state: String? }
        /// Core types the first task only once the agent reports that it is ready; a start-up prompt leaves it unsent.
        struct FirstMessage: Decodable, Sendable, Equatable { let sent: Bool? }
        let address: String; let name: String; let state: String; let createdMs: UInt64; let template: String?; let status: Status?
        var firstMessage: FirstMessage? = nil
        var isLive: Bool { state == "live" }
    }

    struct Workspace: Decodable, Sendable { let core: String?; let version: String?; let agents: [Agent]; let templates: [Template] }

    struct Profile: Decodable, Sendable { let id: Int; let runtimeName: String }

    /// One saved row of a session: `task` (what was sent) or `reply` (what the agent's hook saved).
    /// Other kinds (files, snapshots) carry no text; they decode with an empty one and are skipped.
    struct Item: Decodable, Sendable, Equatable {
        let id: Int; let kind: String; let text: String
        enum CodingKeys: CodingKey { case id, kind, text }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        }
    }

    /// A task on its way: the session it went to and the last saved row before it, so its reply is the next one.
    struct Turn: Sendable, Equatable { let core: String; let address: String; let createdMs: UInt64; let after: Int; let launched: Bool }

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
    /// Between two reads of a session while waiting for its reply.
    var pollInterval: Duration = .seconds(1)

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

    func launch(name: String, template: String, task: String, profileID: Int?) async throws -> Agent {
        var body: [String: Any] = ["name": name, "template": template, "task": task]
        if let profileID { body["profile_id"] = profileID }
        return try await post("/api/agents", body)
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

    /// The live agent for this bot: the same name, or the same id suffix after a rename.
    func liveAgent(named name: String, in workspace: Workspace) -> Agent? {
        let live = workspace.agents.filter(\.isLive)
        return live.first { $0.name == name } ?? live.first { Self.suffix(of: $0.name) == Self.suffix(of: name) }
    }

    /// Types `text` into this bot's running agent, or starts one from `template` with `text` as its first task.
    /// A bot that ran before keeps its saved profile, so its earlier sessions stay together in the workspace.
    func deliver(_ text: String, name: String, template: String?) async throws -> Turn {
        let current = try await workspace()
        guard let core = current.core else { throw Failure.http(503, "Herdr Core is not running on the workspace's machine.") }
        if let agent = liveAgent(named: name, in: current) {
            let after = try await history(core: core, address: agent.address, createdMs: agent.createdMs).map(\.id).max() ?? 0
            try await message(text, to: agent)
            return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: after, launched: false)
        }
        let usable = current.templates.filter { $0.error == nil }
        guard let chosen = usable.first(where: { $0.name == template }) ?? (template == nil ? usable.first : nil) else { throw Failure.noTemplate }
        let known = try await profiles().first { $0.runtimeName == name || Self.suffix(of: $0.runtimeName) == Self.suffix(of: name) }
        let agent = try await launch(name: known?.runtimeName ?? name, template: chosen.name, task: text, profileID: known?.id)
        if agent.firstMessage?.sent == false { throw Failure.waitingAtPrompt }
        return Turn(core: core, address: agent.address, createdMs: agent.createdMs, after: 0, launched: true)
    }

    /// Waits for the reply the agent's hook saves after `turn`, telling `status` what the agent reports meanwhile.
    /// An agent that goes quiet without saving one (its hook was not trusted, or it stopped at a prompt) ends the wait.
    /// `quietPolls` outlasts the bridge's 30 s limit on that hook, which a busy disk on the server can use up.
    func reply(to turn: Turn, quietPolls: Int = 45, status: @Sendable (String) -> Void = { _ in }) async throws -> String {
        var quiet = 0, last = ""
        while true {
            try Task.checkCancellation()
            let items = try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs)
            if let reply = items.first(where: { $0.kind == "reply" && $0.id > turn.after }) { return reply.text }
            let agent = try await workspace().agents.first { $0.address == turn.address && $0.createdMs == turn.createdMs }
            guard let agent, agent.isLive else {
                // One more read: the hook may have saved the reply as the session closed.
                let final = try await history(core: turn.core, address: turn.address, createdMs: turn.createdMs)
                if let reply = final.first(where: { $0.kind == "reply" && $0.id > turn.after }) { return reply.text }
                throw Failure.ended
            }
            let state = agent.status?.state ?? ""
            let line = Self.statusLine(state)
            if line != last { status(line); last = line }
            // "done" or "idle" with nothing saved: the hook may still be writing; stop waiting once it cannot be.
            quiet = (state == "done" || state == "idle") ? quiet + 1 : 0
            if quiet >= quietPolls { throw Failure.silent }
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

    private func get<T: Decodable>(_ path: String) async throws -> T { try await send(request(path, method: "GET", body: nil)) }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
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

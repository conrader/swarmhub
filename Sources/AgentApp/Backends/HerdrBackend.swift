import Foundation

/// An agent that Herdr Core runs in a terminal (Claude Code, Codex, or any other template), reached through the
/// SwarmHub bridge (`HerdrClient`). The agent program keeps its own conversation, model, tools and permissions, so
/// only the newest user message is sent: `systemPrompt`, earlier `messages` and images go nowhere. The reply arrives
/// whole when the agent finishes its turn (its Stop hook saves it), not token by token.
///
/// There are no server sessions for the app to manage (`sessionTransport` is nil, like Mock): one bot is one agent
/// on the bridge, named from the bot (`HerdrClient.agentName`), started on its first message and reused while it runs.
struct HerdrBackend: AgentBackend {
    static let defaultURL = "http://127.0.0.1:8787"
    /// `UserDefaults`: the bridge address and the template new bots start from. The token is Keychain account `herdr`.
    static let urlKey = "herdrBaseURL", templateKey = "herdrTemplate", keyAccount = "herdr"
    /// A bot's own template lives beside the app settings, so the bot record and its Hermes fields stay untouched.
    static func botTemplateKey(_ botID: UUID) -> String { "\(templateKey).\(botID.uuidString.lowercased())" }
    static let missingToken = "Paste the Herdr workspace access token in Settings → Advanced → Servers and keys."
    static let modelNote = "The model comes from the agent program on the Herdr machine. Choose it in the Herdr template."

    let kind = BackendKind.herdr
    let client: HerdrClient
    let agentName: String
    /// nil: the first template the bridge can start.
    let template: String?

    init(client: HerdrClient, botName: String, botID: UUID, template: String?) {
        self.client = client; self.template = template?.isEmpty == false ? template : nil
        agentName = HerdrClient.agentName(for: botName, suffix: botID.uuidString.replacingOccurrences(of: "-", with: ""))
    }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let text = request.messages.last(where: { $0.role == "user" })?.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendError.unavailable("There is no message to send to the agent.")
        }
        let backend = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.status("Sending to Herdr"))
                    let turn = try await backend.client.deliver(text, name: backend.agentName, template: backend.template)
                    let reply = try await backend.client.reply(to: turn) { continuation.yield(.status($0)) }
                    continuation.yield(.token(reply)); continuation.yield(.completed); continuation.finish()
                } catch is CancellationError { continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listSessions() async throws -> [BackendSession] { [] }

    func cancel(sessionID: String) async throws -> StopOutcome { try await requestStop(try await stopTarget(sessionID: sessionID)) }

    /// The bot's running agent, as `address/created`; an agent that is not running has nothing to stop.
    func stopTarget(sessionID: String) async throws -> StopTarget {
        guard let agent = client.liveAgent(named: agentName, in: try await client.workspace()) else { return .noActiveRun }
        return .serverRun("\(agent.address)/\(agent.createdMs)")
    }

    /// Herdr presses the agent's own interrupt key; the agent stays open for the next message.
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        guard case .serverRun(let id) = target else { return .noActiveRun }
        guard let agent = try await client.workspace().agents.first(where: { "\($0.address)/\($0.createdMs)" == id && $0.isLive }) else { return .noActiveRun }
        try await client.interrupt(agent)
        return .requested
    }

    func resolveApproval(id: UUID, approved: Bool) async throws {
        throw BackendError.unavailable("Answer this request in the agent's terminal in the Herdr workspace.")
    }

    /// Settings → Test: the bridge answers, Core is up, and how many templates it can start.
    func testConnection() async throws -> String {
        let workspace = try await client.workspace()
        guard workspace.core != nil else { throw BackendError.unavailable("The workspace answered, but Herdr Core is not running beside it.") }
        let usable = workspace.templates.filter { $0.error == nil }.map(\.name)
        if usable.isEmpty { return "Connected to Herdr Core \(workspace.version ?? ""), but it has no agent template yet." }
        return "Connected to Herdr Core \(workspace.version ?? "") · templates: \(usable.joined(separator: ", "))"
    }
}

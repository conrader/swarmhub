import Foundation

/// An agent that Herdr Core runs in a terminal (Claude Code, Codex, or any other template), reached through the
/// SwarmHub bridge (`HerdrClient`). The agent program keeps its own conversation, model, tools and permissions, so
/// only the newest user message is sent (after the bot's own instructions, once, when an agent starts):
/// `systemPrompt`, earlier `messages` and images go nowhere. The reply is
/// saved by the agent's Stop hook when its turn ends; a template that publishes a preview (Claude Code with
/// `--workspace-preview`) also shows it growing line by line, and one that does not (Codex) shows it whole.
/// Both agents report their tool calls through hooks, which become the reply's activity steps.
///
/// There are no server sessions for the app to manage (`sessionTransport` is nil, like Mock): one bot is one agent
/// on the bridge, named from the bot (`HerdrClient.agentName`), started on its first message and reused while it runs.
struct HerdrBackend: AgentBackend {
    static let defaultURL = "http://127.0.0.1:8787"
    /// `UserDefaults`: the template new bots start from, and the one bridge address an install had before it kept a
    /// list of servers (`HerdrServer`); that first server's token is still Keychain account `herdr`.
    static let urlKey = "herdrBaseURL", templateKey = "herdrTemplate", keyAccount = "herdr"
    /// Used only when the Keychain has no token (`AppStore.herdrClient`).
    static let tokenEnvironment = "SWARMHUB_HERDR_TOKEN"
    /// A bot's own template lives beside the app settings, so the bot record and its Hermes fields stay untouched.
    static func botTemplateKey(_ botID: UUID) -> String { "\(templateKey).\(botID.uuidString.lowercased())" }
    static let missingToken = "This Herdr server has no access token yet. Add it in Settings → Advanced → Servers and keys."
    static let modelNote = "Choose this agent's model under Herdr agent."
    static func botModelKey(_ botID: UUID) -> String { "herdrModel.\(botID.uuidString.lowercased())" }

    let kind = BackendKind.herdr
    let client: HerdrClient
    let agentName: String
    /// nil: the first template the bridge can start.
    let template: String?
    /// nil: the agent program's own default model. Used when the bot next starts an agent.
    let model: String?
    /// The bot's own instructions, given once to each agent it starts; the app's Hermes policy text is never sent.
    let instructions: String?
    /// A message sent while the agent answers is typed into the running agent (steer), which reads it as soon as it
    /// can. Off: the app holds the message until the answer ends.
    var steers = true
    static func botSteerKey(_ botID: UUID) -> String { "herdrSteer.\(botID.uuidString.lowercased())" }
    /// Set for a bot that may create bots (`HerdrBotRequest.note`): how to ask the app for one. A new agent reads it
    /// after its instructions; a running agent, which may have started before the bot was allowed to, reads it again
    /// in front of a message that asks for a bot.
    var creationNote: String? = nil

    /// What a new agent is told once: the bot's own instructions, cut so the note after them always fits.
    var launchInstructions: String? {
        guard let note = creationNote, !note.isEmpty else { return instructions }
        let own = HerdrClient.plain(instructions ?? "", bytes: max(0, HerdrClient.instructionsBytes - note.utf8.count - 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? note : own + "\n\n" + note
    }

    init(client: HerdrClient, botName: String, botID: UUID, template: String?, model: String? = nil, instructions: String? = nil) {
        self.client = client; self.template = template?.isEmpty == false ? template : nil
        self.model = model?.isEmpty == false ? model : nil
        self.instructions = instructions == Bot.defaultPersona ? nil : instructions
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
                    let turn = try await backend.client.deliver(text, name: backend.agentName, template: backend.template, model: backend.model, instructions: backend.launchInstructions,
                                                                reminder: ManagementIntent.createsBot(text) ? backend.creationNote : nil)
                    // The preview is the reply so far, so each update and the saved reply replace the row's text.
                    let reply = try await backend.client.reply(to: turn, status: { continuation.yield(.status($0)) },
                                                               tool: { call, isNew in Self.toolEvents(call, isNew: isNew).forEach { continuation.yield(.tool($0)) } },
                                                               partial: { continuation.yield(.replace($0)) })
                    continuation.yield(.replace(reply)); continuation.yield(.completed); continuation.finish()
                } catch is CancellationError { continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A reported call as the chat's activity steps: its start when it is new, and its end once the agent's hook has
    /// seen one. A call first seen already finished (a quick tool between two reads) yields both.
    static func toolEvents(_ call: HerdrClient.ToolCall, isNew: Bool) -> [ToolEvent] {
        let name = toolName(call.tool), id = "herdr-\(call.seq)"
        let started = isNew ? [ToolEvent(phase: .started, name: name, preview: ToolEvent.preview(call.detail), callID: id)] : []
        return call.finished ? started + [ToolEvent(phase: call.failed ? .failed : .completed, name: name, callID: id)] : started
    }

    /// Claude Code's and Codex's tool names in the words `ActivityCopy.label` already knows ("Running a command",
    /// "Reading a file", "Editing a file"); any other tool keeps its own name.
    static func toolName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "bashoutput", "killshell": "bash"
        case "read", "grep", "glob", "ls", "notebookread", "view_image": "read_file"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch": "edit_file"
        case "websearch", "web_search": "web_search"
        case "webfetch", "web_fetch": "fetch"
        case "task", "agent": "delegate_task"
        case "todowrite", "update_plan": "todo"
        default: tool
        }
    }

    func features() async throws -> Set<String> { steers ? ["run_steer"] : [] }

    /// Types the message into the running agent. Claude Code and Codex keep their own queue for input that arrives
    /// mid-turn, so nothing is handed back; with no agent running there is nothing to steer.
    func steer(sessionID: String, text: String) async throws {
        guard steers else { throw BackendError.unavailable("This bot holds messages until its answer ends.") }
        guard let agent = client.liveAgent(named: agentName, in: try await client.workspace()) else { throw BackendError.http(404, "run_not_found") }
        try await client.message(HerdrClient.plain(text, bytes: HerdrClient.messageBytes), to: agent)
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

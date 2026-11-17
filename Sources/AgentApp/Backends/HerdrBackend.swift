import Foundation

/// An agent that Herdr Core runs in a terminal (Claude Code, Codex, or any other template), reached through the
/// SwarmHub bridge (`HerdrClient`). The agent program keeps its own conversation, model, tools and permissions, so
/// only the newest user message is sent (after the bot's own instructions, once, when an agent starts):
/// `systemPrompt`, earlier `messages` and images go nowhere. The reply is saved by the agent's Stop hook when its
/// turn ends. Until then the reply so far is shown as it is written: Claude Code, Codex and OpenCode all publish it
/// through the bridge, and both report their tool calls through hooks, which become the reply's activity steps.
/// A turn is followed on the bridge's event stream (`HerdrEvents.swift`), and by polling where there is none.
///
/// There are no server sessions for the app to manage (`sessionTransport` is nil, like Mock): one bot is one agent
/// on the bridge, named from the bot (`HerdrClient.agentName`), started on its first message, or ahead of it when its
/// chat opens (`HerdrClient.warm`), and reused while it runs. While a turn waits, the chat says what for
/// (`HerdrTurnStatus`).
struct HerdrBackend: AgentBackend {
    static let defaultURL = "http://127.0.0.1:8787"
    /// `UserDefaults`: the template new bots start from, and the one bridge address an install had before it kept a
    /// list of servers (`HerdrServer`); that first server's token is still Keychain account `herdr`.
    static let urlKey = "herdrBaseURL", templateKey = "herdrTemplate", keyAccount = "herdr"
    /// Used only when the Keychain has no token (`AppStore.herdrClient`).
    static let tokenEnvironment = "SWARMHUB_HERDR_TOKEN"
    /// A bot's own template lives beside the app settings, not on the bot record.
    static func botTemplateKey(_ botID: UUID) -> String { "\(templateKey).\(botID.uuidString.lowercased())" }
    static let missingToken = "This server's access key is missing. Open Settings → Servers and press Check connection."
    static let modelNote = "Choose this bot's model in its Details, under Model."
    static func botModelKey(_ botID: UUID) -> String { "herdrModel.\(botID.uuidString.lowercased())" }

    let kind = BackendKind.herdr
    let client: HerdrClient
    let agentName: String
    /// nil: the first template the bridge can start.
    let template: String?
    /// nil: the agent program's own default model. Used when the bot next starts an agent.
    let model: String?
    /// The bot's own instructions, given once to each agent it starts; nothing else of the app's is sent.
    let instructions: String?
    /// A message sent while the agent answers is typed into the running agent (steer), which reads it as soon as it
    /// can. Off: the app holds the message until the answer ends.
    var coordinate: (@Sendable () async throws -> Bool)?
    var confirmation: HerdrModelConfirmation?
    var serverID: String?
    var steers = true
    static func botSteerKey(_ botID: UUID) -> String { "herdrSteer.\(botID.uuidString.lowercased())" }
    /// Set for a server's main bot (`HerdrBotRequest.note`): how to have the app create a bot, and how to answer
    /// another bot's request for one. A new agent reads it after its instructions; a running agent reads it once, and
    /// again in front of a message that asks for a bot.
    var creationNote: String? = nil
    /// Set for every other bot (`HerdrBotAsk.note`): how to ask the main bot for a bot. Delivered like `creationNote`.
    var askNote: String? = nil
    /// Set for a bot that may start helper agents (`HerdrHelperNote.text`): how to start one and how to choose its
    /// difficulty. A new agent reads it after its instructions; a running agent that has not read it yet reads it in
    /// front of its next message, once (`HerdrClient.deliver`'s `once`).
    var helperNote: String? = nil
    /// Set for every bot (`HerdrBotMessage.note`): how to write to another bot of the server. Delivered like
    /// `helperNote`. `roster` is the line of names it can write to: a new agent reads it after the notes, and a
    /// running agent again, alone, whenever it has changed (`HerdrClient.deliver`'s `changing`).
    var messageNote: String? = nil, roster: String? = nil
    /// "About you" (`HerdrAboutYou`): what the app keeps about the person. `aboutYou` is the text with its lead, given
    /// to every bot: a new agent reads it after the notes, and a running agent again, alone, whenever it has changed,
    /// like `roster`. `aboutHow` is set for a server's main bot only: how to propose an addition; delivered like
    /// `helperNote`.
    var aboutYou: String? = nil, aboutHow: String? = nil
    /// The projects on other servers this bot may use (`HerdrProjects.swift`): a new agent is launched with them and
    /// told by the bridge itself; a running agent is told when the list has changed. `projectsChanged`: the list
    /// changed since the bot's running agent was last given it, so the next message gives it first, and
    /// `onProjectsSynced` hears that it did.
    var projects: [HerdrBotProject] = [], projectsChanged = false
    var onProjectsSynced: (@Sendable () -> Void)? = nil
    /// Hears, while a turn runs, the agent's helpers as the stream reports them and whether the stream is delivering
    /// (`HerdrClient.LiveNote`): the bot's helper rows then need no polling of their own.
    var onLive: (@Sendable (HerdrClient.LiveNote) -> Void)? = nil
    /// Set while the app is starting this bot's agent ahead of time (`AppStore+HerdrWarm.swift`): `settled` returns
    /// when that start has gone through or failed. A message waits for it, so it finds the agent instead of starting
    /// another; meanwhile the chat says that `program` is starting.
    struct Starting: Sendable { let program: String?; let settled: @Sendable () async -> Void }
    var starting: Starting? = nil

    static let teamNote = """
    SwarmHub team commands: use swarmhub-herdr bot list to find peers, bot ask NAME "QUESTION" for a reply, or bot handoff NAME "TASK" to delegate. Use checkin ci PUBLIC_PR_URL "WHAT" for a GitHub CI failure watch, checkin list for plans and promise list for commitments. Use the command path in your SwarmHub instructions when provided. Report the result to the person in this chat.
    """
    static let publishMarker = "Publishing a requested deliverable"
    static let publishNote = """
    Publishing a requested deliverable: when the user asks for a file or a Page, publish the finished version before your final reply. Use "${SWARMHUB_PUBLISHER:-swarmhub-herdr}" publish-file PATH for a file, or "${SWARMHUB_PUBLISHER:-swarmhub-herdr}" publish-page "Title" < report.md for a Page. The user can open a successful publication from the reply.
    """

    /// The app's notes for this bot, each with the phrase that shows an agent has read it.
    var notes: [(marker: String, note: String)] {
        [(HerdrBotRequest.marker, creationNote), (HerdrBotAsk.marker, askNote), (HerdrHelperNote.marker, helperNote), (messageNote == Self.teamNote ? "SwarmHub team commands:" : HerdrBotMessage.marker, messageNote),
         (HerdrAboutYou.marker, aboutHow), (Self.publishMarker, serverID == nil ? nil : Self.publishNote)].compactMap { marker, note in
            note.flatMap { $0.isEmpty ? nil : (marker, $0) }
        }
    }

    /// The notes that change, each with the words every version of it starts with.
    var rosters: [(lead: String, note: String)] {
        (aboutYou.flatMap { $0.isEmpty ? nil : [(HerdrAboutYou.lead, $0)] } ?? []) + (roster.flatMap { $0.isEmpty ? nil : [(HerdrBotMessage.rosterLead, $0)] } ?? [])
    }

    /// What a new agent is told once: the bot's own instructions, then the notes. The notes have their own room
    /// (`HerdrClient.notesBytes`), so they never shorten the bot's instructions.
    var launchInstructions: String? {
        let told = HerdrClient.plain((notes.map(\.note) + rosters.map(\.note)).joined(separator: "\n\n"), bytes: HerdrClient.notesBytes)
        guard !told.isEmpty else { return instructions }
        let own = HerdrClient.plain(instructions ?? "", bytes: HerdrClient.instructionsBytes - 2).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? told : own + "\n\n" + told
    }

    init(client: HerdrClient, botName: String, botID: UUID, template: String?, model: String? = nil, instructions: String? = nil) {
        self.client = client; self.template = template?.isEmpty == false ? template : nil
        self.model = model?.isEmpty == false ? model : nil
        self.instructions = instructions == Bot.defaultPersona ? nil : instructions
        agentName = Self.agentName(botName: botName, botID: botID)
    }

    /// The bridge's name for a bot's agent: readable, and ending in the start of the bot's id.
    static func agentName(botName: String, botID: UUID) -> String {
        HerdrClient.agentName(for: botName, suffix: botID.uuidString.replacingOccurrences(of: "-", with: ""))
    }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        guard let text = request.messages.last(where: { $0.role == "user" })?.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackendError.unavailable("There is no message to send.")
        }
        var configured = self
        if try await coordinate?() == true {
            configured.roster = nil
            configured.messageNote = Self.teamNote
        }
        let backend = configured
        return AsyncThrowingStream { continuation in
            let task = Task {
                let started = ContinuousClock.now
                do {
                    // A start ahead of time that is still on its way ends first, so this message never starts a second agent.
                    if let starting = backend.starting {
                        continuation.yield(.status(HerdrTurnStatus.starting(program: starting.program).code))
                        await starting.settled()
                    }
                    continuation.yield(.status(HerdrTurnStatus.sending.code))
                    let turn = try await backend.client.deliver(text, name: backend.agentName, template: backend.template, model: backend.model, instructions: backend.launchInstructions,
                                                                reminder: ManagementIntent.createsBot(text) ? backend.creationNote ?? backend.askNote : nil,
                                                                once: backend.notes, changing: backend.rosters,
                                                                projects: backend.projects, resync: backend.projectsChanged, synced: { backend.onProjectsSynced?() },
                                                                status: { continuation.yield(.status($0.code)) })
                    continuation.yield(.status(HerdrTurnStatus.of(agentState: "", program: turn.program, began: false, starting: turn.starting).code))
                    // The preview is the reply so far, so each update and the saved reply replace the row's text.
                    // Read the launch model from this exact session. Following the answer proceeds concurrently.
                    let modelRead = Task {
                        let ref = HerdrClient.AgentRef(address: turn.address, createdMs: turn.createdMs)
                        if turn.program?.lowercased() == "opencode",
                           let state = try? await backend.client.sessionModel(ref, core: turn.core), let model = state.effective {
                            continuation.yield(.launchModel(model))
                            return
                        }
                        if let saved = backend.confirmation, saved.matches(server: backend.serverID, core: turn.core, agent: ref) {
                            continuation.yield(.launchModel(saved.label))
                            return
                        }
                        let profiles = try? await backend.client.profiles()
                        let sessions = profiles?.lazy.flatMap { $0.sessions ?? [] }
                        let runtime = sessions?.first { $0.address == turn.address && $0.createdMs == turn.createdMs }?.runtime
                        if let model = runtime?.model ?? runtime?.modelId, !model.isEmpty, !Task.isCancelled {
                            continuation.yield(.launchModel(model))
                        }
                    }
                    defer { modelRead.cancel() }
                    let reply = try await backend.client.replyWithActivity(to: turn, status: { continuation.yield(.status($0.code)) },
                                                               tool: { call, isNew in Self.toolEvents(call, isNew: isNew).forEach { continuation.yield(.tool($0)) } },
                                                               partial: { continuation.yield(.replace($0)) }, live: { backend.onLive?($0) },
                                                               published: { result in
                                                                   if let serverID = backend.serverID { continuation.yield(.published(serverID, result)) }
                                                               })
                    if let server = backend.serverID, !reply.ids.isEmpty {
                        continuation.yield(.journal(server, reply.ids))
                    }
                    continuation.yield(.replace(reply.text))
                    continuation.yield(.runActivity(seconds: Int(started.duration(to: .now).components.seconds), tools: reply.tools))
                    continuation.yield(.completed)
                    continuation.finish()
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

    /// Settings → Test: the bridge answers, Core is up, and how many templates it can start.
    func testConnection() async throws -> String {
        let workspace = try await client.workspace()
        guard workspace.core != nil else { throw BackendError.unavailable("The server answered, but Herdr Core is not running on it. Start Herdr Core there, then check again.") }
        let usable = workspace.templates.filter { $0.error == nil }.map(\.name)
        let names = HerdrProgramName.labels(for: workspace.templates.filter { $0.error == nil })
        if usable.isEmpty { return "Connected, but no AI is set up on this server yet. Add one there, then check again." }
        return "Connected. Bots can run on \(usable.compactMap { names[$0] }.joined(separator: ", "))."
    }
}

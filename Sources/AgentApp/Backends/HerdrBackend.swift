import CryptoKit
import Foundation

/// An agent that Herdr Core runs in a terminal (Claude Code, Codex, or any other template), reached through the
/// SwarmHub bridge (`HerdrClient`). The agent program keeps its own conversation, model, tools and permissions, so
/// only the newest user message is sent (after the bot's own instructions, once, when an agent starts):
/// The bridge receives the newest user message and its attachments. A bot that came with an earlier conversation is
/// the one exception: each agent it starts reads that conversation first, in a turn of its own (`HerdrHandoff`).
/// The reply is saved by the agent's Stop hook when its
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
    let botID: UUID
    private let accepted = LockedValue<(sessionID: String, target: StopTarget)?>(nil)
    private let groupSends = GroupSendTasks()
    /// True from the start of a turn that may hand the bot's earlier conversation over until that step has ended:
    /// meanwhile the turn takes no steer (`features`), so a message the person sends then waits its turn instead of
    /// being typed into the handoff.
    private let handingOver = LockedValue(false)
    /// nil: the first template the bridge can start.
    let template: String?
    /// nil: the agent program's own default model. Used when the bot next starts an agent.
    let model: String?
    /// The bot's own instructions, given once to each agent it starts. Beside them the app sends only its notes
    /// below and, for an imported bot, the earlier conversation (`handoff`).
    let instructions: String?
    /// A message sent while the agent answers is typed into the running agent (steer), which reads it as soon as it
    /// can. An unsupported steer retains an unsent receipt in chat.
    var coordinate: (@Sendable () async throws -> Bool)?
    var confirmation: HerdrModelConfirmation?
    var serverID: String?
    var steers = true
    static func botSteerKey(_ botID: UUID) -> String { "herdrSteer.\(botID.uuidString.lowercased())" }
    /// Set for a server's main bot (`HerdrBotRequest.note`): how to have the app create a bot, and how to answer
    /// another bot's request for one. A new agent reads it after its instructions; a running agent reads it once, and
    /// again in front of a message that asks for a bot.
    var creationNote: String? = nil
    /// How to have the app change which agent program and model bots run on (`HerdrModelRequest`). `modelBrief` is
    /// set for a server's main bot and delivered like `helperNote`; `modelHow` is the fuller text, or for every other
    /// bot who can do it instead, and is read only in front of a message that asks for such a change.
    var modelBrief: String? = nil, modelHow: String? = nil
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
    var onLive: (@Sendable (HerdrClient.LiveNote, String?) -> Void)? = nil
    /// Set while the app is starting this bot's agent ahead of time (`AppStore+HerdrWarm.swift`): `settled` returns
    /// when that start has gone through or failed. A message waits for it, so it finds the agent instead of starting
    /// another; meanwhile the chat says that `program` is starting.
    struct Starting: Sendable { let program: String?; let settled: @Sendable () async -> Void }
    var starting: Starting? = nil
    /// Set for a bot that came with an earlier conversation (one imported from Grok Bot, `AppStore+GrokHandoff.swift`):
    /// before a message, the bot's own agent is handed that conversation as files, unless its session has read it.
    /// Never for the agent a bot has in a group. nil: nothing but the message is sent.
    var handoff: HerdrHandoffSource? = nil
    var prepareDirect: (@MainActor @Sendable () async throws -> [HerdrHandoffSource])?

    static let teamNote = """
    SwarmHub team commands: use swarmhub-herdr bot list to find peers, bot ask NAME "QUESTION" for a reply, or bot handoff NAME "TASK" to delegate. Use checkin ci PUBLIC_PR_URL "WHAT" for a GitHub CI failure watch, checkin list for plans and promise list for commitments. Use the command path in your SwarmHub instructions when provided. After fixing a blocker, resume the authorized task and verify the requested outcome. For a previously declined handoff, check whether the sender reassigned or canceled it before retrying, then report the result to the sender and the person.
    """
    static let publishMarker = "Publishing a requested deliverable"
    static let publishNote = """
    Publishing a requested deliverable: when the user asks for a file or a Page, publish the finished version before your final reply. Use "${SWARMHUB_PUBLISHER:-swarmhub-herdr}" publish-file PATH for a file, or "${SWARMHUB_PUBLISHER:-swarmhub-herdr}" publish-page "Title" < report.md for a Page. Publish images and videos with their file extensions so the person can view them in chat.
    """
    static let choiceMarker = "Choice cards for the person"
    static let choiceNote = """
    \(choiceMarker): When you need the person to choose, end your reply with a `choices` fence. Put the question first and each short answer on a `- ` list line. Include Yes and No for a yes/no question, or Both when it is an option. Use `choices-multiple` with the same list format when several answers are allowed. The person checks options, can add text, then sends one reply.

    ```choices
    Which way should I go?
    - Start now
    - Wait for Infra
    ```
    """
    static let draftMarker = "Drafts for approval"
    static let draftNote = """
    \(draftMarker): For an email or outbound message the user must approve before sending, use a `draft` fence. Put optional `channel:` (e.g. Email, WhatsApp, Slack), `to:`, and `subject:` (email) headers on separate lines, then a blank line and the exact body. SwarmHub shows a card with Edit, Copy, and Send. On “Send this edited draft”, send the JSON fields and body verbatim.

    ```draft
    channel: Email
    to: maya@example.com
    subject: Launch update

    Hi Maya, we're ready to launch.
    ```
    """

    /// The app's notes for this bot, each with the phrase that shows an agent has read it.
    var notes: [(marker: String, note: String)] {
        [(HerdrModelRequest.marker, modelBrief), (Self.choiceMarker, Self.choiceNote), (Self.draftMarker, Self.draftNote),
         (HerdrBotRequest.marker, creationNote), (HerdrBotAsk.marker, askNote), (HerdrHelperNote.marker, helperNote), (messageNote == Self.teamNote ? "After fixing a blocker, resume the authorized task" : HerdrBotMessage.marker, messageNote),
         (HerdrAboutYou.marker, aboutHow), (Self.publishMarker, serverID == nil ? nil : Self.publishNote)].compactMap { marker, note in
            note.flatMap { $0.isEmpty ? nil : (marker, $0) }
        }
    }

    func managementReminder(for text: String) -> String? {
        let notes = [ManagementIntent.changesModel(text) ? modelHow : nil,
                     ManagementIntent.createsBot(text) ? creationNote ?? askNote : nil].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
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
        self.botID = botID
        self.client = client; self.template = template?.isEmpty == false ? template : nil
        self.model = model?.isEmpty == false ? model : nil
        self.instructions = instructions == Bot.defaultPersona ? nil : instructions
        agentName = Self.agentName(botName: botName, botID: botID)
    }

    /// The bridge's name for a bot's agent: readable, and ending in the start of the bot's id.
    static func agentName(botName: String, botID: UUID) -> String {
        HerdrClient.agentName(for: botName, suffix: botID.uuidString.replacingOccurrences(of: "-", with: ""))
    }

    func runtimeName(sessionID: String) -> String {
        Self.groupRuntimeName(sessionID: sessionID, botID: botID) ?? agentName
    }

    static func groupRuntimeName(sessionID: String, botID: UUID) -> String? {
        let groupSuffix = String(sessionID.suffix(79))
        guard groupSuffix.hasPrefix("group-"),
              UUID(uuidString: String(groupSuffix.dropFirst(6).prefix(36))) != nil,
              UUID(uuidString: String(groupSuffix.suffix(36))) == botID else { return nil }
        let digest = SHA256.hash(data: Data(sessionID.utf8))
        return "group-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func goalBlocker(sessionID: String) async throws -> String? {
        let name = runtimeName(sessionID: sessionID)
        if !(try await client.approvals(for: name)).isEmpty {
            return "Review the pending workspace approval, then resume the goal."
        }
        let workspace = try await client.workspace()
        switch client.liveAgent(named: name, in: workspace)?.status?.state {
        case "blocked": return "Resolve the workspace prompt, then resume the goal."
        case "working": return "The workspace agent is still working. Review its result before resuming."
        default: return nil
        }
    }

    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let input = request.messages.last(where: { $0.role == "user" })?.content ?? ""
        let images = try request.images.map { url -> HerdrClient.TaskFile in
            guard let comma = url.firstIndex(of: ","), url.hasPrefix("data:image/"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { throw BackendError.unavailable("Could not read the attached image.") }
            let mime = String(url.dropFirst(5).prefix { $0 != ";" && $0 != "," })
            return .init(name: "image.\(mime.split(separator: "/").last ?? "png")", mime: mime, data: data)
        }
        let files = request.files + images
        let blank = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !blank || !files.isEmpty else { throw BackendError.unavailable("There is no message to send.") }
        let text = blank ? "Read the attached files." : input
        let sessionID = request.sessionID
        let name = runtimeName(sessionID: sessionID)
        try HerdrClient.validateMessage(text)
        try HerdrClient.TaskFile.validate(files)
        var configured = self
        if name == agentName, try await coordinate?() == true {
            configured.roster = nil
            configured.messageNote = Self.teamNote
        }
        let backend = configured
        _ = accepted.swap(nil)
        _ = handingOver.swap(name == agentName && (handoff != nil || prepareDirect != nil))
        return AsyncThrowingStream { continuation in
            let produce: @Sendable () async -> Void = {
                let started = ContinuousClock.now
                var delivered = false
                do {
                    // A start ahead of time that is still on its way ends first, so this message never starts a second agent.
                    if name == backend.agentName, let starting = backend.starting {
                        continuation.yield(.status(HerdrTurnStatus.starting(program: starting.program).code))
                        await starting.settled()
                    }
                    continuation.yield(.status(HerdrTurnStatus.sending.code))
                    // The agent reads the bot's earlier conversation first, once per agent session (`HerdrHandoff.swift`).
                    // A handoff that fails does not hold the message back: it goes as it always did, and the source hears why.
                    var missed: [(HerdrHandoffSource, String)] = []
                    if name == backend.agentName {
                        let sources: [HerdrHandoffSource]
                        if let prepare = backend.prepareDirect { sources = try await prepare() }
                        else { sources = [backend.handoff].compactMap { $0 } }
                        for source in sources {
                            if let why = try await backend.handOver(source, status: { _ = continuation.yield(.status($0.code)) }) {
                                missed.append((source, why))
                            }
                        }
                        _ = backend.handingOver.swap(false)
                        if !sources.isEmpty { continuation.yield(.status(HerdrTurnStatus.sending.code)) }
                    }
                    let turn = try await backend.client.deliver(text, name: name, template: backend.template, model: backend.model, instructions: backend.launchInstructions,
                                                                reminder: backend.managementReminder(for: text),
                                                                once: backend.notes, changing: backend.rosters,
                                                                projects: backend.projects, files: files, workspaceID: backend.botID, resync: backend.projectsChanged, synced: { backend.onProjectsSynced?() },
                                                                status: { continuation.yield(.status($0.code)) })
                    delivered = true
                    let target = StopTarget.serverRun("\(turn.core)/\(turn.address)/\(turn.createdMs)")
                    _ = backend.accepted.swap((sessionID, target))
                    for (source, why) in missed { source.failed?(HerdrHandoffFailure(launch: backend.launch(of: turn), why: why)) }
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
                        let runtime = sessions?.first { ($0.core == nil || $0.core == turn.core) && $0.address == turn.address && $0.createdMs == turn.createdMs }?.runtime
                        if let model = runtime?.model ?? runtime?.modelId, !model.isEmpty, !Task.isCancelled {
                            continuation.yield(.launchModel(model))
                        }
                    }
                    defer { modelRead.cancel() }
                    let reply = try await backend.client.replyWithActivity(to: turn, status: { continuation.yield(.status($0.code)) },
                                                               tool: { call, isNew in Self.toolEvents(call, isNew: isNew).forEach { continuation.yield(.tool($0)) } },
                                                               partial: { continuation.yield(.replace($0)) }, live: { backend.onLive?($0, name == backend.agentName ? nil : name) },
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
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where name != backend.agentName && error.code == .cancelled && Task.isCancelled {
                    continuation.finish()
                } catch HerdrClient.Failure.notDelivered(let reason) {
                    continuation.finish(throwing: HerdrClient.Failure.notDelivered(reason))
                } catch {
                    continuation.finish(throwing: delivered ? StreamBreak(delivered: true, underlying: error) : error)
                }
            }
            if name == agentName {
                let task = Task(operation: produce)
                continuation.onTermination = { _ in task.cancel() }
            } else {
                guard let task = groupSends.start(sessionID: sessionID, produce: produce) else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.onTermination = { [groupSends] _ in
                    task.cancel()
                    groupSends.remove(task, sessionID: sessionID)
                }
            }
        }
    }

    /// A reported call as the chat's activity steps: its start when it is new, and its end once the agent's hook has
    /// seen one. A call first seen already finished (a quick tool between two reads) yields both.
    static func toolEvents(_ call: HerdrClient.ToolCall, isNew: Bool) -> [ToolEvent] {
        let name = toolName(call.tool), id = "herdr-\(call.seq)"
        let started = isNew ? [ToolEvent(phase: .started, name: name, preview: ToolEvent.preview(call.detail), callID: id)] : []
        return call.finished ? started + [ToolEvent(phase: call.failed ? .failed : .completed, name: name, callID: id)] : started
    }

    /// Claude Code's, Codex's and Gemini CLI's tool names in the words `ActivityCopy.label` already knows ("Running a command",
    /// "Reading a file", "Editing a file"); any other tool keeps its own name.
    static func toolName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "exec", "exec_command", "local_shell", "bashoutput", "killshell", "run_shell_command": "bash"
        case "read", "grep", "glob", "ls", "notebookread", "view_image", "read_many_files", "list_directory", "grep_search", "search_file_content": "read_file"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch", "write_file", "replace": "edit_file"
        case "websearch", "web_search", "google_web_search": "web_search"
        case "webfetch", "web_fetch": "fetch"
        case "task", "agent": "delegate_task"
        case "todowrite", "update_plan", "write_todos": "todo"
        default: tool
        }
    }

    /// Nothing while the bot's earlier conversation is being handed over: that turn is not the person's to steer.
    func features() async throws -> Set<String> { steers && !handingOver.current && accepted.current?.steerReference != nil ? ["run_steer"] : [] }

    func steer(sessionID: String, text: String) async throws {
        try await steer(sessionID: sessionID, text: text, files: [])
    }

    func steer(sessionID: String, text: String, files: [HerdrClient.TaskFile]) async throws {
        guard steers, !handingOver.current, let turn = accepted.current else {
            throw BackendError.unavailable("This turn is not ready for live guidance.")
        }
        try await client.steer(turn, text: text, files: files)
    }

    func cancelGroupSend(sessionID: String) { groupSends.cancel(sessionID: sessionID) }

    func cancel(sessionID: String) async throws -> StopOutcome {
        cancelGroupSend(sessionID: sessionID)
        return try await requestStop(try await stopTarget(sessionID: sessionID))
    }

    /// The bot's running agent, as `address/created`; an agent that is not running has nothing to stop.
    func stopTarget(sessionID: String) async throws -> StopTarget {
        if let accepted = accepted.current, accepted.sessionID == sessionID { return accepted.target }
        // The bridge may have accepted the message before its HTTP response reached this stream.
        let workspace = try await client.workspace()
        if let accepted = accepted.current, accepted.sessionID == sessionID { return accepted.target }
        guard let core = workspace.core,
              let agent = client.liveAgent(named: runtimeName(sessionID: sessionID), in: workspace) else { return .noActiveRun }
        return .serverRun("\(core)/\(agent.address)/\(agent.createdMs)")
    }

    /// Herdr presses the agent's own interrupt key; the agent stays open for the next message.
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        guard case .serverRun(let id) = target else { return .noActiveRun }
        let workspace = try await client.workspace()
        guard let core = workspace.core,
              let agent = workspace.agents.first(where: { "\(core)/\($0.address)/\($0.createdMs)" == id && $0.isLive }) else { return .noActiveRun }
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

/// The group consumer and the stream producer are separate tasks. Stop must cancel a producer
/// even while it is still preparing the first POST and the consumer has yet to read the stream.
private final class GroupSendTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    func start(sessionID: String, produce: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.withLock {
            guard !Task.isCancelled else { return nil }
            let task = Task(operation: produce)
            tasks[sessionID] = task
            return task
        }
    }

    func cancel(sessionID: String) {
        let task = lock.withLock { tasks[sessionID] }
        task?.cancel()
    }

    func remove(_ task: Task<Void, Never>, sessionID: String) {
        lock.withLock {
            if tasks[sessionID] == task { tasks[sessionID] = nil }
        }
    }
}

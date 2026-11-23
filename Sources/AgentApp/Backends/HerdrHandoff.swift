import Foundation

/// An earlier conversation as it is handed to a bot's agent before the person's message, so that the agent can carry
/// on from it (`GrokHandoff` makes one for a bot imported from Grok Bot).
/// The agent program keeps the conversation itself and a new agent starts with none, so each agent session is given
/// the handoff once: as a turn of its own that the chat does not show, with the conversation attached as files.
/// Whether a session has had it: the Mac remembers the one launch of the bot's agent that replied to it
/// (`HerdrHandoffSource.read`); for any other launch the session's saved rows on the server are searched for a task
/// that carries `lead` with a reply after it (`HerdrClient.handoffState`). The rows alone are not enough, because the
/// server shows only a session's newest rows and the marker leaves them in a long conversation. A new agent (after a
/// restart of the Mac, the server or the bot) is another launch with no such task, so it is handed the conversation
/// again by itself.
/// A handoff that fails never holds the person's message back: the message goes as it would have gone without one,
/// and the app says once in the chat that the conversation could not be handed over (`HerdrBackend.handOver`).
struct HerdrHandoff: Sendable {
    /// How often a handoff is tried by itself for one launch of the agent.
    static let attempts = 2
    /// How long the agent may take to reply to it before the person's message goes without it.
    static let replyLimit: Duration = .seconds(300)
    /// The most the note's own excerpt holds when the files go with it: the server adds the files' paths and its own
    /// hints to the same task, and they need room too.
    static let excerptBytes = 3_000

    /// `lead` is how the marker of this conversation starts, whatever its revision; `marker` is the whole of it,
    /// which the note begins with.
    let lead: String, marker: String
    /// The file to read first, then the complete transcript to search.
    let files: [HerdrClient.TaskFile]
    /// The summary of the older part when there is one, and the last exchanges as short blocks, oldest first. The
    /// note carries one of them inline, for an agent that cannot open the files.
    let summary: String?, recent: [String]
    /// How many messages the summary stands for and how many are there word for word: what the app says afterwards.
    var olderMessages = 0, recentMessages = 0
    var origin: Origin = .imported

    /// Where the conversation comes from, which decides how the agent is told about it and what its files are called.
    enum Origin: Sendable, Equatable {
        /// A conversation that was imported from another app (`GrokHandoff`).
        case imported
        /// The bot's own chat so far, for an agent that starts fresh after the bot's agent program or model was
        /// changed (`AppStore+HerdrCarryOver.swift`).
        case ownChat

        var handoffFile: String { self == .imported ? "grok-handoff.md" : "conversation-so-far.md" }
        var fullFile: String { self == .imported ? "grok-history-full.md" : "conversation-full.md" }
        /// What the note says first, after the marker.
        var opening: String {
            switch self {
            case .imported: "You are continuing an existing conversation that moved here from another app. It is older than anything already said in this chat; messages written here since the move are not in it."
            case .ownChat: "You are continuing a conversation this bot already had with the person in this chat. The agent that held it was replaced by you, because another agent program or model was chosen, so you start without it: this is the conversation up to now."
            }
        }
    }

    /// The note the handoff travels in, at most `bytes` long: the marker, what to do with the files, and an excerpt
    /// (the summary, else the last exchanges, as much as still fits). `withFiles` false: the server takes no files,
    /// so the excerpt is all the agent gets.
    func note(bytes: Int, withFiles: Bool) -> String {
        var lines: [String] = []
        lines.append("\(marker) \(origin.opening)")
        if withFiles {
            let first = files.first?.name ?? "the first attached file"
            let second = files.count > 1 ? files[1].name : "the other attached file"
            lines.append("Read the attached file \(first) now, before anything else. The attached \(second) is the complete transcript: search it when you need something older, do not read it whole. The paths of both are listed at the end of this message.")
        } else {
            lines.append("This server could not take the files that hold the conversation, so the excerpt below is all of it you have.")
        }
        lines.append("Secrets were replaced by \(GrokRedactor.marker). Reply with one line that says where things stood, and nothing else: the person's next message follows.")
        let head = lines.joined(separator: "\n")
        let title: String
        if summary == nil {
            title = withFiles ? "The last messages, in case you cannot open the files:" : "The last messages:"
        } else {
            title = withFiles ? "A summary, in case you cannot open the files:" : "A summary of the conversation:"
        }
        let fits = bytes - head.utf8.count - title.utf8.count - 4
        let room = withFiles ? min(fits, Self.excerptBytes) : fits
        var excerpt = ""
        if let text = summary {
            excerpt = HerdrClient.plain(text, bytes: max(0, room))
        } else {
            // The newest blocks that fit, in the order they were said.
            var kept: [String] = []
            var used = 0
            for block in recent.reversed() {
                let size = block.utf8.count + 1
                if used + size > room { break }
                used += size
                kept.append(block)
            }
            excerpt = kept.reversed().joined(separator: "\n")
        }
        let shown = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = shown.isEmpty ? head : head + "\n\n" + title + "\n" + shown
        return HerdrClient.plain(whole, bytes: bytes)
    }

    /// Why a handoff failed, in a plain sentence. nil for what would stop the person's message just the same (no
    /// connection, a server that does not let the app in) and for the person's own Stop: those are left to the message.
    static func reason(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let broken = error as? URLError {
            if broken.code == .cancelled || TurnOutcome.certainlyUnsentCodes.contains(broken.code) { return nil }
            return "The connection to the server broke off or took too long."
        }
        if error is HerdrClient.SummaryTimeout { return "Reading it took too long." }
        if let failure = error as? HerdrClient.Failure {
            switch failure {
            case .invalidURL, .unauthorized, .refusedHost: return nil
            case .silent: return "Its agent finished without a reply."
            case .ended: return "Its agent stopped while reading it."
            case .waitingAtPrompt, .notDelivered: return "Its agent was waiting at a prompt in its terminal."
            case .unconfirmedDelivery: return "The server could not confirm that it arrived."
            case .noTemplate: return "This server has no AI the bot can run on."
            case .http(_, let message): return "The server said: \(message)"
            }
        }
        return error.localizedDescription
    }
}

/// One launch of an agent as its server names it: its address and the moment it was created, on one Core of one
/// server. The next agent a bot starts is another launch.
struct HerdrAgentLaunch: Codable, Equatable, Sendable {
    /// The app's id of the server; nil where there is none (a check).
    var server: String?
    var core: String
    var address: String
    var createdMs: UInt64
}

/// What a source hears when an agent has replied to a handoff: which launch it was, and what went to it. `handoff` is
/// nil when the reply was found in the session's rows, or was waited for after an earlier attempt sent it.
struct HerdrHandoffReceipt: Sendable {
    let launch: HerdrAgentLaunch
    var handoff: HerdrHandoff? = nil
    /// False: the server took no files, so only the note with its excerpt went.
    var withFiles = true
}

/// A handoff that failed while the person's message went through: the launch the message went to, and why.
struct HerdrHandoffFailure: Sendable, Equatable {
    let launch: HerdrAgentLaunch
    let why: String
}

/// Where a bot's handoff comes from (`HerdrBackend.handoff`). Making one reads the whole conversation and may wait
/// for a summary, so it is asked for only once the agent session is known not to have had it.
struct HerdrHandoffSource: Sendable {
    /// `HerdrHandoff.lead` of the conversation.
    let lead: String
    /// Makes the handoff. It tells `status` when it waits for the summary of the older part (a bounded time).
    /// nil: there is nothing to hand over, and the message goes as it always did.
    let prepare: @Sendable (_ status: @escaping @Sendable (HerdrTurnStatus) -> Void) async -> HerdrHandoff?
    /// The launch the Mac remembers as having replied to the handoff. While it is the bot's running agent nothing is
    /// sent and the session's rows are not read.
    var read: HerdrAgentLaunch? = nil
    /// The launch the handoff last failed for, and how often in a row. At `HerdrHandoff.attempts` it is not tried
    /// again for that launch.
    var failedFor: HerdrAgentLaunch? = nil, failures = 0
    var replyLimit: Duration = HerdrHandoff.replyLimit
    /// Hears that an agent has replied to the handoff.
    var delivered: (@Sendable (HerdrHandoffReceipt) -> Void)? = nil
    /// Hears that the handoff failed and the person's message went without it.
    var failed: (@Sendable (HerdrHandoffFailure) -> Void)? = nil
}

extension HerdrClient {
    /// How far a handoff has got in one agent session, as the session's saved rows show it.
    enum HandoffState: Sendable, Equatable {
        /// No task that reached the agent carries the marker.
        case missing
        /// The newest task that carries it (its row id) has no reply after it: it is still being read, or it was
        /// stopped or lost.
        case unanswered(task: Int)
        /// The agent replied after it. Which revision it read is not looked at: an agent that read an older one is
        /// not told what was added since (the place to compare `HerdrHandoff.marker` when it is).
        case delivered
    }

    static func handoffState(lead: String, rows: [Item]) -> HandoffState {
        let ordered = rows.sorted { $0.id < $1.id }
        guard let task = ordered.last(where: { $0.reachedAgent && $0.text.contains(lead) }) else { return .missing }
        let answered = ordered.contains { $0.kind == "reply" && $0.id > task.id }
        return answered ? .delivered : .unanswered(task: task.id)
    }

    /// A bot's agent session as one read of the server shows it: the bot's running agent, when it has one, and that
    /// session's saved rows.
    struct HandoffSession: Sendable {
        let workspace: Workspace
        let core: String
        let agent: Agent?
        let rows: [Item]
    }

    func handoffSession(name: String) async throws -> HandoffSession { try await handoffSession(name: name, in: try await workspace()) }

    /// The same from a list of agents that was just read.
    func handoffSession(name: String, in current: Workspace) async throws -> HandoffSession {
        guard let core = current.core else { throw Failure.http(503, "Herdr Core is not running on the server. Start it there, then try again.") }
        guard let agent = liveAgent(named: name, in: current) else { return HandoffSession(workspace: current, core: core, agent: nil, rows: []) }
        let rows = try await history(core: core, address: agent.address, createdMs: agent.createdMs)
        return HandoffSession(workspace: current, core: core, agent: agent, rows: rows)
    }

    /// What a message to the bot has to do about the handoff first.
    enum HandoffStanding: Sendable, Equatable {
        /// The session has read it: nothing.
        case delivered
        /// It was sent and the agent is still on it (working, starting, or waiting at a prompt in its terminal):
        /// wait for that reply instead of sending it twice.
        case running(Turn)
        /// Send it: there is no agent, the session never had it, or the one it had was stopped or lost.
        case needed
    }

    func handoffStanding(lead: String, in session: HandoffSession) -> HandoffStanding {
        guard let agent = session.agent else { return .needed }
        switch Self.handoffState(lead: lead, rows: session.rows) {
        case .missing: return .needed
        case .delivered: return .delivered
        case .unanswered(let task):
            let state = agent.status?.state ?? ""
            guard state == "working" || state == "blocked" || agent.isStarting else { return .needed }
            return .running(Turn(core: session.core, address: agent.address, createdMs: agent.createdMs, after: task, launched: false,
                                 program: session.workspace.program(of: agent), queued: agent.isStarting))
        }
    }

    /// A handoff on its way: the turn whose reply shows that the agent has read it, and whether the files went with it.
    struct HandoffSent: Sendable {
        let turn: Turn
        var withFiles = true
    }

    /// Gives the bot's agent session the handoff, unless it has it. Returns the turn whose reply shows that the
    /// agent has read it; nil when the session had read it already.
    /// The files should land where the agent may read them, and for a new agent that is its own workspace folder. So:
    /// with no agent, one is launched with the note as its first task and the files attached. An agent that was
    /// started ahead of time and has had no task yet is ended and launched again the same way. An agent
    /// that holds a conversation is sent the note with the files. The note carries an excerpt in every case, so an
    /// agent that cannot open a file still knows where things stood.
    /// A first task carries `persona` only, not the app's notes: those go in front of the person's message, which a
    /// running agent that has not read them gets anyway (`deliver`'s `once`), and that leaves the note its room.
    /// A server that takes no files gets the note alone.
    func handOver(_ handoff: HerdrHandoff, name: String, template: String?, model: String?, persona: String?, projects: [HerdrBotProject] = [],
                  workspaceID: UUID? = nil, status: @Sendable (HerdrTurnStatus) -> Void = { _ in }) async throws -> HandoffSent? {
        let session = try await handoffSession(name: name)
        switch handoffStanding(lead: handoff.lead, in: session) {
        case .delivered: return nil
        case .running(let turn): return HandoffSent(turn: turn)
        case .needed: break
        }
        let current = session.workspace
        let own = Self.plain(persona ?? "", bytes: Self.instructionsBytes).trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions: String? = own.isEmpty ? nil : own
        let withFiles = current.attachments == true && !handoff.files.isEmpty
        let files: [TaskFile] = withFiles ? handoff.files : []
        // The room a first message has beside the instructions when files go with it; every way of sending fits in it.
        let note = handoff.note(bytes: Self.firstMessageBudget(instructions: instructions, hasFiles: true), withFiles: withFiles)
        // Like `endUnused`: only an agent the server itself calls unused (`warm`), with no task that reached it.
        if let agent = session.agent, agent.warm == true, withFiles, current.launchAttachments == true, !session.rows.contains(where: { $0.reachedAgent }) {
            try await end(agent)
            status(.starting(program: Self.program(template: template, in: current)))
            let started = try await start(name: name, template: template, model: model, task: Self.firstTask(note, instructions: instructions),
                                          projects: projects.map(\.id), workspaceID: workspaceID, files: files, in: current)
            if started.openCodeFirstTask == "uncertain" { throw Failure.unconfirmedDelivery }
            if started.openCodeFirstTask == "not_sent" { throw Failure.notDelivered("OpenCode did not accept the first task.") }
            if started.firstMessage?.sent == false { throw Failure.waitingAtPrompt }
            let turn = Turn(core: session.core, address: started.address, createdMs: started.createdMs, after: 0, launched: true, program: current.program(of: started))
            return HandoffSent(turn: turn, withFiles: withFiles)
        }
        let turn = try await deliver(note, name: name, template: template, model: model, instructions: instructions, projects: projects,
                                     files: files, workspaceID: workspaceID, status: status)
        return HandoffSent(turn: turn, withFiles: withFiles)
    }
}

extension HerdrBackend {
    /// The launch a turn went to, as the Mac remembers launches.
    func launch(of turn: HerdrClient.Turn) -> HerdrAgentLaunch {
        HerdrAgentLaunch(server: serverID, core: turn.core, address: turn.address, createdMs: turn.createdMs)
    }

    /// The step before a message to this bot's own agent: the agent reads the bot's earlier conversation first,
    /// unless its session has. Returns when the agent has replied to it, or when there was nothing to do.
    /// It never holds the person's message back. When the handoff fails (the server refuses the files, the agent
    /// stays silent, stops, waits at a prompt, or takes longer than `replyLimit`), the reason comes back as a plain
    /// sentence and the caller sends the message as it would have gone without a handoff, then tells
    /// `source.failed`. After `HerdrHandoff.attempts` failures for one launch nothing is tried for that launch.
    /// Only what would stop the message just the same is thrown: no connection, and the person's Stop.
    func handOver(_ source: HerdrHandoffSource, status: @escaping @Sendable (HerdrTurnStatus) -> Void) async throws -> String? {
        let current = try await client.workspace()
        // With Core down the message cannot go either, and says so itself.
        guard let core = current.core else { return nil }
        let live = client.liveAgent(named: agentName, in: current)
        let running: HerdrAgentLaunch? = live.map { HerdrAgentLaunch(server: serverID, core: core, address: $0.address, createdMs: $0.createdMs) }
        if let running, running == source.read { return nil }
        if let running, running == source.failedFor, source.failures >= HerdrHandoff.attempts { return nil }
        do {
            try await handOver(source, in: current, running: running, status: status)
            return nil
        } catch {
            guard let why = HerdrHandoff.reason(error) else { throw error }
            return why
        }
    }

    /// One attempt: sends the handoff when the session needs it and waits for the agent's reply.
    private func handOver(_ source: HerdrHandoffSource, in current: HerdrClient.Workspace, running: HerdrAgentLaunch?,
                          status: @escaping @Sendable (HerdrTurnStatus) -> Void) async throws {
        let session = try await client.handoffSession(name: agentName, in: current)
        var receipt: HerdrHandoffReceipt? = nil
        let pending: HerdrClient.Turn?
        switch client.handoffStanding(lead: source.lead, in: session) {
        case .delivered:
            // Found in the rows: remembered, so that it is still known when the marker has left them.
            if let running { source.delivered?(HerdrHandoffReceipt(launch: running)) }
            return
        case .running(let followed): pending = followed
        case .needed:
            guard let handoff = await source.prepare(status) else { return }
            guard let sent = try await client.handOver(handoff, name: agentName, template: template, model: model, persona: instructions,
                                                       projects: projects, workspaceID: botID, status: status) else { return }
            pending = sent.turn
            receipt = HerdrHandoffReceipt(launch: launch(of: sent.turn), handoff: handoff, withFiles: sent.withFiles)
        }
        guard let turn = pending else { return }
        status(.readingHistory)
        let reader = self.client
        _ = try await HerdrClient.within(source.replyLimit) {
            try await reader.reply(to: turn, status: { now in status(HerdrTurnStatus.duringHandoff(now)) })
        }
        source.delivered?(receipt ?? HerdrHandoffReceipt(launch: launch(of: turn)))
    }
}

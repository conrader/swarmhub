import Foundation

/// Whether a Herdr bot's agent is running, as the chat header says it. A bot with no agent has no entry.
enum HerdrAgentReadiness: Equatable, Sendable {
    /// Its agent program is starting (`program`: the server's name for it); a message sent now waits for it.
    case starting(program: String?)
    /// Running and ready: a message is answered without waiting for the agent program to start.
    case ready
    /// Running, but showing a prompt in its terminal: it takes no message until the person has answered there.
    case blocked(program: String?)

    /// What the server's list says about a bot's agent; nil when it has none.
    init?(_ agent: HerdrClient.Agent?, in workspace: HerdrClient.Workspace) { self.init(agent, program: agent.flatMap(workspace.program(of:))) }

    init?(_ agent: HerdrClient.Agent?, program: String?) {
        guard let agent, agent.isLive else { return nil }
        if agent.isStarting { self = .starting(program: program) } else if agent.status?.state == "blocked" { self = .blocked(program: program) } else { self = .ready }
    }

    var isStarting: Bool { if case .starting = self { true } else { false } }
    var isBlocked: Bool { if case .blocked = self { true } else { false } }

    /// The header's word, and what it means when the pointer rests on it.
    var word: String {
        switch self {
        case .starting(let program): "Starting \(program ?? "its agent")…"
        case .ready: "Ready"
        case .blocked: "Waiting for you in its terminal"
        }
    }

    var help: String {
        switch self {
        case .starting: "Its agent program is starting. You can write now: your message is delivered as soon as the agent is ready."
        case .ready: "Its agent is running, so a reply starts at once."
        case .blocked(let program): "\(program ?? "Its agent") shows a prompt and waits for your answer there. Open the Herdr workspace to answer it: a message does not reach the agent until then."
        }
    }
}

/// Starting a Herdr bot's agent ahead of its first message. An agent program takes from several seconds to a minute to
/// start, and a first message used to wait for all of it. So the app starts the agent of the bot whose chat is on
/// screen (when the chat opens, at launch, and when the app comes back to the front) if none is running, with no task:
/// the first message then finds a running agent and carries what a first task carries (`HerdrClient.deliver`).
/// Only the bot on screen, never the whole roster, and never a second agent for a bot: a message sent while a start
/// is on its way waits for it (`HerdrBackend.starting`). A start that fails changes nothing: the first message starts
/// the agent as before. The server ends an agent that is never written to after its own idle limit.
extension AppStore {
    // MARK: The switch

    /// "Keep its agent ready", on unless the person turned it off.
    static func herdrKeepsReadyKey(_ botID: UUID) -> String { "herdrKeepReady.\(botID.uuidString.lowercased())" }
    func herdrKeepsReady(_ bot: Bot) -> Bool { defaults.object(forKey: Self.herdrKeepsReadyKey(bot.id)) as? Bool ?? true }

    func setHerdrKeepsReady(_ on: Bool, for bot: Bot) {
        defaults.set(on, forKey: Self.herdrKeepsReadyKey(bot.id)); objectWillChange.send()
        if on, launchWorkEnabled, selectedGroup == nil, selectedBot?.id == bot.id { warmHerdrAgent(for: bot) }
    }

    /// False once the bot's server has refused to start its agent program ahead of time: an older server refuses
    /// every program, a newer one only a program that must be given its first task as it starts. Kept until the app
    /// quits, so a server is asked once for each program.
    func herdrStartsAhead(for bot: Bot) -> Bool { !herdrNoWarmStarts.contains(herdrWarmKey(for: bot)) }
    private func herdrWarmKey(for bot: Bot) -> String { "\(herdrServer(for: bot).id)|\(herdrTemplate(for: bot) ?? "")" }

    /// The server's name for the agent program this bot starts, once its server was read (`refreshHerdrAgentReading`).
    func herdrProgramName(for bot: Bot) -> String? { herdrAgentReadings[bot.id]?.runtime?.runtime?.harness }

    /// What the switch means, in the words of the state it is in.
    nonisolated static func keepsReadyCaption(bot: String, program: String?, available: Bool) -> String {
        let program = program ?? "its agent program"
        guard available else { return "This server does not start \(program) ahead of time, so \(bot)’s agent starts with your first message." }
        return "On: \(program) starts when you open \(bot)’s chat, so your first message does not wait for it. The server closes an agent you never write to after a while. Off: the agent starts with your first message."
    }

    // MARK: Starting ahead

    /// A chat that is only passed through on the way to another starts nothing.
    static let herdrWarmDelay: Duration = .milliseconds(800)

    /// The chat of `bot` is on screen: its agent is started ahead of time when it has none. The view's task calls
    /// this, so leaving the chat within `herdrWarmDelay` cancels it.
    func herdrChatShown(_ bot: Bot) async {
        try? await Task.sleep(for: Self.herdrWarmDelay)
        if Task.isCancelled { return }
        warmHerdrAgent(for: bot)
    }

    /// The app came back to the front with `bot`'s chat on screen: an agent the server closed meanwhile is started again.
    func herdrChatReturned(_ bot: Bot) {
        guard herdrReadiness[bot.id] == nil else { return }
        warmHerdrAgent(for: bot)
    }

    /// Starts `bot`'s agent ahead of time when it has none, in the background, with the name, server, agent program,
    /// model and projects its first message would start it with. Nothing happens for a bot that is answering (its
    /// turn starts the agent, or has one), whose start is already on its way, whose switch is off, or whose server
    /// does not start agents ahead of time. Returns the start that was begun, for callers that wait for it.
    /// `replacingUnused`: the bot's agent program or model was just changed, so an agent that was started ahead of
    /// time and has not been written to is ended first, and the new one starts as now chosen. An agent that has had
    /// a message is never ended here.
    @discardableResult func warmHerdrAgent(for bot: Bot, replacingUnused: Bool = false) -> Task<Void, Never>? {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo, herdrWarming[bot.id] == nil,
              !runningTurns.values.contains(where: { $0.botID == bot.id }), herdrStartsAhead(for: bot),
              let backend = try? herdrBackend(for: bot) else { return nil }
        let starts = herdrKeepsReady(bot)
        guard starts || replacingUnused else { return nil }
        let id = bot.id, refused = herdrWarmKey(for: bot)
        let task = Task { [weak self] in
            if replacingUnused, (try? await backend.client.endUnused(name: backend.agentName)) == true { self?.herdrReadiness[id] = nil }
            let outcome = starts ? try? await backend.client.warm(name: backend.agentName, template: backend.template, model: backend.model, projects: backend.projects) : nil
            guard let self else { return }
            self.herdrWarming[id] = nil
            switch outcome {
            case .started(let agent, let program)?:
                // A new agent has the bot's projects as they are now.
                if backend.projectsChanged { backend.onProjectsSynced?() }
                self.herdrReadiness[id] = HerdrAgentReadiness(agent, program: program)
                // What the running agent was started on, for Details; a message that waits for this start does not wait for that.
                if let bot = self.bots.first(where: { $0.id == id }) { Task { await self.refreshHerdrAgentReading(for: bot) } }
            case .running(let agent, let program)?:
                self.herdrReadiness[id] = HerdrAgentReadiness(agent, program: program)
            case .unavailable?: self.herdrNoWarmStarts.insert(refused)
            // The server could not be read, or refused this start: the first message starts the agent as before.
            case nil: break
            }
        }
        herdrWarming[id] = task
        return task
    }

    /// The bot's agent program, model or projects were changed: an agent that was started ahead of time and has not
    /// been written to is replaced by one that starts as now chosen, also when its start is still on its way.
    func herdrChoiceChanged(for bot: Bot) async {
        await herdrWarming[bot.id]?.value
        await warmHerdrAgent(for: bot, replacingUnused: true)?.value
    }

    /// What one read of a server's agents says about `watched` bots (`refreshHerdrHelpers` reads it anyway): which
    /// have an agent, and whether it is ready. A bot that is no longer watched is forgotten, so the header never
    /// repeats an old reading.
    func noteHerdrReadiness(_ read: [UUID: HerdrAgentReadiness?], watched: [Bot]) {
        var now = herdrReadiness.filter { entry in watched.contains { $0.id == entry.key } || herdrWarming[entry.key] != nil || runningTurns.values.contains { $0.botID == entry.key } }
        for (id, readiness) in read { now[id] = readiness }
        if now != herdrReadiness { herdrReadiness = now }
    }
}

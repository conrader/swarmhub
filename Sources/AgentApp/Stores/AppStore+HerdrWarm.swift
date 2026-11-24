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
        if agent.status?.state == "blocked" { self = .blocked(program: program) } else if agent.isStarting { self = .starting(program: program) } else { self = .ready }
    }

    var isStarting: Bool { if case .starting = self { true } else { false } }
    var isBlocked: Bool { if case .blocked = self { true } else { false } }

    /// The header's word, and what it means when the pointer rests on it.
    var word: String {
        switch self {
        case .starting(let program): "Starting \(program ?? "its agent")…"
        case .ready: "Ready"
        case .blocked: "Check terminal"
        }
    }

    var help: String {
        switch self {
        case .starting: "It is starting. You can write now: your message is delivered as soon as it is ready."
        case .ready: "Ready: a reply starts at once."
        case .blocked(let program): "The terminal status for \(program ?? "this agent") needs another check."
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
    func herdrProgramName(for bot: Bot) -> String? { herdrAgentReadings[bot.id]?.runtime?.programName }

    /// What the switch means, in the words of the state it is in.
    nonisolated static func keepsReadyCaption(bot: String, program: String?, available: Bool) -> String {
        guard available else { return "This server cannot start \(bot) ahead of time, so it starts with your first message." }
        return "\(bot) starts when you open its chat, so the first reply comes sooner. Off: it starts with your first message."
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
        guard storeRestoreOffer == nil, bot.backend == .herdr, !bot.isReadOnlyArchive, !bot.isDemo, herdrWarming[bot.id] == nil,
              !runningTurns.values.contains(where: { $0.botID == bot.id }), herdrStartsAhead(for: bot),
              let backend = try? herdrBackend(for: bot) else { return nil }
        let starts = herdrKeepsReady(bot)
        guard starts || replacingUnused else { return nil }
        let id = bot.id, refused = herdrWarmKey(for: bot), server = herdrServer(for: bot)
        let task = Task { [weak self] in
            if replacingUnused, (try? await backend.client.endUnused(name: backend.agentName)) == true {
                self?.herdrReadiness[id] = nil
                self?.clearAutoSwitch(id)
            }
            let outcome = starts ? try? await backend.client.warm(name: backend.agentName, template: backend.template, model: backend.model, projects: backend.projects, workspaceID: backend.botID) : nil
            guard let self else { return }
            self.herdrWarming[id] = nil
            guard self.bots.contains(bot), self.herdrServer(for: bot) == server else { return }
            switch outcome {
            case .started(let agent, let program)?:
                // A new agent has the bot's projects and Auto mode as they are now.
                self.clearAutoSwitch(id)
                if backend.projectsChanged { backend.onProjectsSynced?() }
                self.herdrReadiness[id] = HerdrAgentReadiness(agent, program: program)
                self.herdrAgentPresence[id] = HerdrAgentPresence(server: server, agent: agent)
                // What the running agent was started on, for Details; a message that waits for this start does not wait for that.
                if let bot = self.bots.first(where: { $0.id == id }) { Task { await self.refreshHerdrAgentReading(for: bot) } }
            case .running(let agent, let program)?:
                self.herdrReadiness[id] = HerdrAgentReadiness(agent, program: program)
                self.herdrAgentPresence[id] = HerdrAgentPresence(server: server, agent: agent)
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

    /// What a workspace read says about the watched bots. Each server's poll prunes its own bots' readings.
    func noteHerdrReadiness(_ read: [UUID: HerdrAgentReadiness?], watched: [Bot], on server: HerdrServer? = nil) {
        var keeping = Set(watched.map(\.id)).union(herdrWarming.keys).union(runningTurns.values.compactMap(\.botID))
        if let server {
            for bot in bots where bot.backend == .herdr && herdrServer(for: bot).id != server.id { keeping.insert(bot.id) }
        }
        var now = herdrReadiness.filter { keeping.contains($0.key) }
        for (id, readiness) in read { now[id] = readiness }
        if now != herdrReadiness { herdrReadiness = now }
        else { for bot in watched where herdrWaits(bot).waits { herdrPromptCheck(bot) } }

    }
}

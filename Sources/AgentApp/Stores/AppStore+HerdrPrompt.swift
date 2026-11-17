import AppKit
import Foundation

/// What the store keeps beside the prompts themselves: the bots whose running turn says its agent waits (with the
/// agent program's name), and where a notification goes (tests listen here).
struct HerdrPromptBook {
    var turnWaits: [UUID: String] = [:]
    var notifier: (@MainActor (Bot, String) -> Void)?
}

/// An agent that waits in its terminal, made something the person can act on from the chat. The server says that an
/// agent is "blocked" in two places: in the status of a running turn, and in its list of agents (the chat header).
/// Either makes a prompt for the bot: the app reads what the terminal shows, puts it above the message box with a
/// button that opens that terminal, and raises it once, as an unread mark and a notification (when the bot's and
/// the app's notifications are on). When the agent moves again the prompt goes; the next one is raised anew.
/// Nothing here answers the question: the person does, in the agent's own terminal.
extension AppStore {
    /// The agent program's name when `bot`'s agent waits at a prompt; nil when it does not.
    func herdrWaits(_ bot: Bot) -> (program: String?, waits: Bool) {
        if let program = herdrPromptBook.turnWaits[bot.id] { return (program.isEmpty ? nil : program, true) }
        if case .blocked(let program)? = herdrReadiness[bot.id] { return (program, true) }
        return (nil, false)
    }

    /// A running turn of `bot` reported what it waits for (`consumeTurn`); nil when the turn ended.
    func herdrTurnStatus(_ status: HerdrTurnStatus?, for bot: Bot) {
        if case .blocked(let program)? = status { herdrPromptBook.turnWaits[bot.id] = program ?? "" } else { herdrPromptBook.turnWaits[bot.id] = nil }
        herdrPromptCheck(bot)
    }

    /// Makes or removes `bot`'s prompt as its agent now waits or not. A new prompt is raised, once, and read.
    func herdrPromptCheck(_ bot: Bot) {
        let state = herdrWaits(bot)
        guard state.waits, bot.backend == .herdr, bots.contains(where: { $0.id == bot.id }) else {
            if herdrPrompts[bot.id] != nil { herdrPrompts[bot.id] = nil }
            return
        }
        if var prompt = herdrPrompts[bot.id] {
            if prompt.program == nil, let program = state.program { prompt.program = program; herdrPrompts[bot.id] = prompt }
            return
        }
        let prompt = HerdrPrompt(program: state.program ?? herdrProgramName(for: bot), since: now())
        herdrPrompts[bot.id] = prompt
        raiseHerdrPrompt(prompt, for: bot)
        if launchWorkEnabled { Task { await refreshHerdrPrompt(for: bot) } }
    }

    /// The header's reading changed: every bot it covers, and every bot that has a prompt, is looked at again.
    func herdrPromptsFollowReadiness() {
        let ids = Set(herdrReadiness.keys).union(herdrPrompts.keys)
        for bot in bots where ids.contains(bot.id) { herdrPromptCheck(bot) }
        for id in herdrPrompts.keys where !bots.contains(where: { $0.id == id }) { herdrPrompts[id] = nil }
    }

    /// Once per prompt: the chat is marked unread unless the person is looking at it, and a notification says who waits.
    private func raiseHerdrPrompt(_ prompt: HerdrPrompt, for bot: Bot) {
        let looking = selectedGroup == nil && selectedBot?.id == bot.id && (NSApp?.isActive ?? false)
        if !looking, !bot.manualUnread { bot.manualUnread = true; objectWillChange.send(); save() }
        guard bot.notificationsEnabled else { return }
        if let notifier = herdrPromptBook.notifier { notifier(bot, prompt.notice) } else { notifyIfNeeded(bot: bot, message: prompt.notice) }
    }

    /// Reads what the waiting agent's terminal shows. A server that cannot be read leaves the prompt as it is.
    func refreshHerdrPrompt(for bot: Bot) async {
        guard herdrPrompts[bot.id] != nil, let backend = try? herdrBackend(for: bot) else { return }
        guard let workspace = try? await backend.client.workspace(), let agent = backend.client.liveAgent(named: backend.agentName, in: workspace) else { return }
        let screen = (try? await backend.client.screen(of: agent.ref)).map(HerdrPrompt.question(from:))
        guard var prompt = herdrPrompts[bot.id] else { return }
        prompt.agent = agent.ref
        if prompt.program == nil { prompt.program = workspace.program(of: agent) }
        if let screen, !screen.isEmpty { prompt.question = screen }
        if prompt != herdrPrompts[bot.id] { herdrPrompts[bot.id] = prompt }
    }

    /// How the person gets to the terminal of `bot`'s waiting agent; nil until the agent is known.
    func herdrPromptAnswer(for bot: Bot) -> HerdrPromptAnswer? {
        guard let agent = herdrPrompts[bot.id]?.agent else { return nil }
        let server = herdrServer(for: bot), core = localService.corePath, environment = ProcessInfo.processInfo.environment
        return HerdrPromptAnswer.plan(server: server, address: agent.address, name: bot.name,
                                      localScript: { Self.terminalScript(core: core, address: $0, name: bot.name, environment: environment) },
                                      sshOptions: HerdrTunnel.options(for: server))
    }

    /// Opens the terminal (or the server's page). Returns false when nothing could be opened.
    @discardableResult func answerHerdrPrompt(for bot: Bot) -> Bool {
        switch herdrPromptAnswer(for: bot) {
        case .terminal(let script)?: openInTerminal(script: script, name: bot.name)
        case .browser(let url)?: ExternalLink.open(url)
        case nil: false
        }
    }
}

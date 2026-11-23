import AppKit
import Foundation

/// What the store keeps beside the prompts themselves: the bots whose running turn says its agent waits (with the
/// agent program's name), and where a notification goes (tests listen here).
struct HerdrPromptBook {
    var refreshing: Set<UUID> = []
    var turnWaits: [UUID: (botID: UUID, program: String)] = [:]
    var notifier: (@MainActor (Bot, GroupChat?, String) -> Void)?
}

/// An agent that waits in its terminal, made something the person can act on from the chat. The server says that an
/// agent is "blocked" in two places: in the status of a running turn, and in its list of agents (the chat header).
/// Either makes a prompt for the bot: the app reads what the terminal shows, puts it above the message box with a
/// button that opens that terminal, and raises it once, as an unread mark and a notification (when the bot's and
/// the app's notifications are on). When the agent moves again the prompt goes; the next one is raised anew.
/// Nothing here answers the question: the person does, in the agent's own terminal.
extension AppStore {
    /// The agent program's name when `bot`'s agent waits at a prompt; nil when it does not.
    func herdrWaits(_ bot: Bot, in group: GroupChat? = nil) -> (program: String?, waits: Bool) {
        if let wait = herdrPromptBook.turnWaits[group?.id ?? bot.id], wait.botID == bot.id {
            return (wait.program.isEmpty ? nil : wait.program, true)
        }
        if group == nil, case .blocked(let program)? = herdrReadiness[bot.id] { return (program, true) }
        return (nil, false)
    }

    /// A running turn of `bot` reported what it waits for (`consumeTurn`); nil when the turn ended.
    func herdrTurnStatus(_ status: HerdrTurnStatus?, for bot: Bot, in group: GroupChat? = nil) {
        let id = group?.id ?? bot.id
        if case .blocked(let program)? = status { herdrPromptBook.turnWaits[id] = (bot.id, program ?? "") }
        else { herdrPromptBook.turnWaits[id] = nil }
        herdrPromptCheck(bot, in: group)
    }

    /// Makes or removes `bot`'s prompt as its agent now waits or not. A new prompt is raised, once, and read.
    func herdrPromptCheck(_ bot: Bot, in group: GroupChat? = nil) {
        let id = group?.id ?? bot.id
        guard herdrWaits(bot, in: group).waits, bot.backend == .herdr, bots.contains(bot),
              group.map(groups.contains) != false else {
            if herdrPrompts[id] != nil { herdrPrompts[id] = nil }
            return
        }
        if launchWorkEnabled || herdrClientSetup != nil { Task { await refreshHerdrPrompt(for: bot, in: group) } }
    }

    /// The header's reading changed: every bot it covers, and every bot that has a prompt, is looked at again.
    func herdrPromptsFollowReadiness() {
        let ids = Set(herdrReadiness.keys).union(herdrPrompts.keys)
        for bot in bots where ids.contains(bot.id) { herdrPromptCheck(bot) }
        let conversations = Set(bots.map(\.id) + groups.map(\.id))
        for id in herdrPrompts.keys where !conversations.contains(id) { herdrPrompts[id] = nil }
    }

    /// Once per prompt: the chat is marked unread unless the person is looking at it, and a notification says who waits.
    private func raiseHerdrPrompt(_ prompt: HerdrPrompt, for bot: Bot, in group: GroupChat?) {
        let looking = openConversation?.id == (group?.id ?? bot.id) && (NSApp?.isActive ?? false)
        if !looking {
            if let group { markUnread(group) }
            else if !bot.manualUnread { bot.manualUnread = true; objectWillChange.send(); save() }
        }
        guard bot.notificationsEnabled, group?.isMuted != true else { return }
        if let notifier = herdrPromptBook.notifier { notifier(bot, group, prompt.notice) }
        else if let group { notifyIfNeeded(group: group, bot: bot, message: prompt.notice) }
        else { notifyIfNeeded(bot: bot, message: prompt.notice) }
    }

    /// Reads what the waiting agent's terminal shows. A server that cannot be read leaves the prompt as it is.
    func refreshHerdrPrompt(for bot: Bot, in group: GroupChat? = nil) async {
        let id = group?.id ?? bot.id
        func stillWaiting() -> Bool { herdrWaits(bot, in: group).waits && bots.contains(bot) && group.map(groups.contains) != false }
        guard stillWaiting(), let backend = try? herdrBackend(for: bot),
              herdrPromptBook.refreshing.insert(id).inserted else { return }
        defer {
            herdrPromptBook.refreshing.remove(id)
            // A new member may have started waiting while the last member's screen was being read.
            if let group, let next = herdrPromptBook.turnWaits[id]?.botID, next != bot.id,
               let member = bots.first(where: { $0.id == next }) { herdrPromptCheck(member, in: group) }
        }
        let name = group.map { backend.runtimeName(sessionID: turnSessionID(in: $0, bot: bot)) } ?? backend.agentName
        guard let workspace = try? await backend.client.workspace(), stillWaiting() else { return }
        let live = backend.client.liveAgent(named: name, in: workspace)
        guard let agent = live, agent.status?.state == "blocked" else {
            herdrPrompts[id] = nil
            if group == nil, herdrReadiness[id]?.isBlocked == true {
                herdrReadiness[id] = HerdrAgentReadiness(live, in: workspace)
            }
            return
        }
        let screen = (try? await backend.client.screen(of: agent.ref)) ?? ""
        guard !Task.isCancelled, stillWaiting() else { return }
        guard HerdrPrompt.actionable(kind: agent.status?.kind, screen: screen) else { herdrPrompts[id] = nil; return }
        let old = herdrPrompts[id]
        let question = HerdrPrompt.question(from: screen)
        let prompt = HerdrPrompt(program: workspace.program(of: agent) ?? herdrWaits(bot, in: group).program,
                                 question: question.isEmpty && old?.agent == agent.ref ? old?.question ?? "" : question, agent: agent.ref,
                                 since: old?.agent == agent.ref ? old?.since ?? now() : now())
        if prompt != old { herdrPrompts[id] = prompt }
        if old?.agent != agent.ref { raiseHerdrPrompt(prompt, for: bot, in: group) }
    }

    /// How the person gets to the terminal of `bot`'s waiting agent; nil until the agent is known.
    func herdrPromptAnswer(for bot: Bot, in group: GroupChat? = nil) -> HerdrPromptAnswer? {
        guard let agent = herdrPrompts[group?.id ?? bot.id]?.agent else { return nil }
        return herdrTerminalAnswer(for: bot, agent: agent)
    }

    private func herdrTerminalAnswer(for bot: Bot, agent: HerdrClient.AgentRef) -> HerdrPromptAnswer? {
        let server = herdrServer(for: bot), core = localService.corePath, environment = ProcessInfo.processInfo.environment
        return HerdrPromptAnswer.plan(server: server, address: agent.address, name: bot.name,
                                      localScript: { Self.terminalScript(core: core, address: $0, name: bot.name, environment: environment) },
                                      sshOptions: HerdrTunnel.options(for: server).map { options in
                                          herdrTunnels.password(for: server) == nil ? options : ["-o", "BatchMode=no"] + options
                                      })
    }

    /// Opens the terminal (or the server's page). Returns false when nothing could be opened.
    @discardableResult func answerHerdrPrompt(for bot: Bot, in group: GroupChat? = nil) -> Bool {
        openHerdrTerminal(herdrPromptAnswer(for: bot, in: group), name: bot.name)
    }

    func viewHerdrTerminal(for bot: Bot, sessionID: String? = nil) async {
        do {
            let backend = try herdrBackend(for: bot)
            let name = sessionID.map(backend.runtimeName(sessionID:)) ?? backend.agentName
            guard let agent = backend.client.liveAgent(named: name, in: try await backend.client.workspace()),
                  openHerdrTerminal(herdrTerminalAnswer(for: bot, agent: agent.ref), name: bot.name) else {
                errorMessage = "The agent’s terminal is no longer available."
                return
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func openHerdrTerminal(_ answer: HerdrPromptAnswer?, name: String) -> Bool {
        switch answer {
        case .terminal(let script)?: openInTerminal(script: script, name: name)
        case .browser(let url)?: ExternalLink.open(url)
        case nil: false
        }
    }
}

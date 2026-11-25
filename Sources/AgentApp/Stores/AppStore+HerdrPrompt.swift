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
    func herdrPromptID(for bot: Bot, in group: GroupChat?) -> UUID {
        guard let group else { return bot.id }
        return runningTurns.first { key, turn in
            key != group.id && turn.conversation === group && turn.botID == bot.id
        }?.key ?? group.id
    }

    func herdrPrompt(for bot: Bot, in group: GroupChat?) -> HerdrPrompt? {
        if let group {
            guard groups.contains(group), group.memberIDs.contains(bot.id),
                  herdrWaits(bot, in: group).waits else { return nil }
        }
        return herdrPrompts[herdrPromptID(for: bot, in: group)]
    }

    /// The agent program's name when `bot`'s agent waits at a prompt; nil when it does not.
    func herdrWaits(_ bot: Bot, in group: GroupChat? = nil) -> (program: String?, waits: Bool) {
        if let wait = herdrPromptBook.turnWaits[herdrPromptID(for: bot, in: group)], wait.botID == bot.id {
            return (wait.program.isEmpty ? nil : wait.program, true)
        }
        if group == nil, case .blocked(let program)? = herdrReadiness[bot.id] { return (program, true) }
        return (nil, false)
    }

    /// A running turn of `bot` reported what it waits for (`consumeTurn`); nil when the turn ended.
    func herdrTurnStatus(_ status: HerdrTurnStatus?, for bot: Bot, in group: GroupChat? = nil) {
        let id = herdrPromptID(for: bot, in: group)
        if case .blocked(let program)? = status { herdrPromptBook.turnWaits[id] = (bot.id, program ?? "") }
        else {
            guard herdrPromptBook.turnWaits[id]?.botID == bot.id else { return }
            herdrPromptBook.turnWaits[id] = nil
        }
        herdrPromptCheck(bot, in: group)
    }

    /// Makes or removes `bot`'s prompt as its agent now waits or not. A new prompt is raised, once, and read.
    func herdrPromptCheck(_ bot: Bot, in group: GroupChat? = nil) {
        let id = herdrPromptID(for: bot, in: group)
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
        let conversations = Set(bots.map(\.id) + groups.map(\.id)).union(runningTurns.keys)
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
        let id = herdrPromptID(for: bot, in: group)
        func stillWaiting() -> Bool {
            herdrPromptID(for: bot, in: group) == id && herdrWaits(bot, in: group).waits && bots.contains(bot)
                && group.map { groups.contains($0) && $0.memberIDs.contains(bot.id) } != false
        }
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
        let program = workspace.program(of: agent) ?? herdrWaits(bot, in: group).program
        let profiles = (try? await backend.client.profiles()) ?? []
        guard stillWaiting(), !Task.isCancelled else { return }
        let runtime = profiles.flatMap { $0.sessions ?? [] }.first { ($0.core == nil || $0.core == workspace.core) && $0.address == agent.address && $0.createdMs == agent.createdMs }?.runtime
        let model = runtime?.model ?? runtime?.modelId ?? "Model unreported"
        let origin = "\(program ?? "Agent") · \(model) · \(agent.address)/\(agent.createdMs)"
        let prompt = HerdrPrompt(origin: origin, reviewDescription: HerdrPrompt.review(for: agent, program: program, question: question), program: program,
                                 needsSignIn: agent.status?.kind?.lowercased() == "auth", question: question.isEmpty && old?.agent == agent.ref ? old?.question ?? "" : question, agent: agent.ref,
                                 since: old?.agent == agent.ref ? old?.since ?? now() : now())
        if prompt != old { herdrPrompts[id] = prompt }
        if old?.agent != agent.ref { raiseHerdrPrompt(prompt, for: bot, in: group) }
    }

    /// How the person gets to the terminal of `bot`'s waiting agent; nil until the agent is known.
    func herdrPromptAnswer(for bot: Bot, in group: GroupChat? = nil) -> HerdrPromptAnswer? {
        guard let agent = herdrPrompt(for: bot, in: group)?.agent else { return nil }
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
                presentError("The agent’s terminal is no longer available.", reason: .terminal, bot: bot)
                return
            }
        } catch { presentError(error.localizedDescription, reason: .terminal, bot: bot) }
    }

    private func openHerdrTerminal(_ answer: HerdrPromptAnswer?, name: String) -> Bool {
        switch answer {
        case .terminal(let script)?: openInTerminal(script: script, name: name)
        case .browser(let url)?: ExternalLink.open(url)
        case nil: false
        }
    }
}

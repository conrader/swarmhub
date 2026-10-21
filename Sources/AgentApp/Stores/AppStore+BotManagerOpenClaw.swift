import Foundation

/// P26: an OpenClaw agent as its Gateway's manager. Same swarmhub ops as P22; `name` is the OpenClaw agent id. There are
/// no keys: a new agent becomes a bot once the Gateway lists it (`agents.list`), bound to (Gateway, agent id).
extension AppStore {
    /// The bot bound to this agent id on the manager's Gateway (the manager itself included).
    func boundOpenClawBot(_ agentID: String, manager: Bot) -> Bot? {
        guard let gatewayID = manager.openClaw?.gatewayID else { return nil }
        let wanted = agentID.lowercased()
        return bots.first { $0.backend == .openClaw && !$0.isReadOnlyArchive && $0.openClaw?.gatewayID == gatewayID && $0.openClaw?.agentID.lowercased() == wanted }
    }

    /// Re-reads the manager's Gateway agent list a few times over ~10 s (`botProbeAttempts` × `botProbeDelay`) and binds
    /// one bot to the agent once it is listed; nil when it never shows up (or the Gateway can't be reached).
    func bindListedAgent(_ agentID: String, manager: Bot) async -> Bot? {
        guard let gateway = gateway(id: manager.openClaw?.gatewayID), HermesKeyPaste.isValidProfileName(agentID) else { return nil }
        for attempt in 0..<max(1, botProbeAttempts) {
            if attempt > 0 { try? await Task.sleep(for: botProbeDelay) }
            guard let listed = try? await openClawHub.agents(for: gateway),
                  let agent = listed.agents.first(where: { $0.id.lowercased() == agentID.lowercased() }) else { continue }
            appendOpenClawBots([agent], gatewayID: gateway.id, only: [agent.id])
            objectWillChange.send(); save()
            return boundOpenClawBot(agent.id, manager: manager)
        }
        return nil
    }

    /// `bot_created` from an OpenClaw manager: bind the new agent, then apply its description and avatar.
    func createOpenClawBot(name: String, description: String, avatar: AvatarMark?, manager: Bot) async {
        guard let bot = await bindListedAgent(name, manager: manager) else {
            notice("Couldn’t see \(name) yet", in: manager); return
        }
        if !description.isEmpty { bot.botDescription = description }
        if let avatar { bot.avatarMark = avatar }
        recordConnectors([.init(name: "defaults", state: .failed, detail: "The manager did not report connector setup. Check this bot's connections.")], for: bot)
        notice("\(manager.name) created \(bot.name)", in: manager)
    }

    /// "Add" on an offer from an OpenClaw manager's `bots` list: binds directly (no key flow).
    func addOfferedOpenClaw(_ offer: BotOffer, manager: Bot) async {
        setOffer(offer.name, .adding, manager: manager)
        guard let bot = await bindListedAgent(offer.name, manager: manager) else { setOffer(offer.name, .unreachable, manager: manager); return }
        if !offer.description.isEmpty { bot.botDescription = offer.description }
        botOffers[manager.id]?.removeAll { $0.name == offer.name }
        objectWillChange.send(); save()
    }
}

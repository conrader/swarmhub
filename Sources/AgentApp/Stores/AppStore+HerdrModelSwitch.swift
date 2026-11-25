import Foundation

extension AppStore {
    func modelSwitchPending(_ bot: Bot) -> Bool { defaults.bool(forKey: "herdr.changeOnSend.\(bot.id)") }

    func markModelSwitch(_ bot: Bot) {
        setHerdrMoveSkipsCarry(false, for: bot)
        defaults.set(true, forKey: "herdr.changeOnSend.\(bot.id)")
    }

    func clearModelSwitch(_ botID: UUID) { defaults.removeObject(forKey: "herdr.changeOnSend.\(botID)") }

    func autoSwitchPending(_ bot: Bot) -> Bool { defaults.bool(forKey: "herdr.autoChangeOnSend.\(bot.id)") }

    func markAutoSwitch(_ bot: Bot) { defaults.set(true, forKey: "herdr.autoChangeOnSend.\(bot.id)") }

    func clearAutoSwitch(_ botID: UUID) { defaults.removeObject(forKey: "herdr.autoChangeOnSend.\(botID)") }

    func herdrExistingAgentNames(for bot: Bot) -> [String] {
        // Older workspace launches have no stored bot ID. Include their direct and group names.
        let direct = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        let groups = groups.filter { $0.memberIDs.contains(bot.id) }.compactMap { group in
            let session = group.session(for: bot.id) ?? sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
            return HerdrBackend.groupRuntimeName(sessionID: session, botID: bot.id)
        }
        return [direct] + groups
    }

    /// Saves this bot's Auto mode setting, replaces any unused warm-started agent immediately, and marks an active
    /// conversation session so the next direct message restarts it with Auto mode and carries the chat over.
    @discardableResult func applyProjectAutoMode(_ enabled: Bool, for bot: Bot, on server: HerdrServer, existingAgents: [String]? = nil) async throws -> HerdrClient.BotAgentSettings {
        let names = existingAgents ?? herdrExistingAgentNames(for: bot)
        let client = try herdrClient(for: server)
        let saved = try await client.setProjectAutoMode(enabled, for: bot.id, existingAgents: names)
        markAutoSwitch(bot)
        if launchWorkEnabled {
            await herdrChoiceChanged(for: bot)
            for groupName in names.dropFirst() {
                _ = try? await client.endUnused(name: groupName)
            }
            await refreshHerdrAgentReading(for: bot)
        }
        return saved
    }

    /// Called inside the direct turn, after an outstanding warm start and before either history or user input.
    /// Reconcile the live session as well as newly changed choices: older app versions only saved the preference.
    func prepareDirectModel(bot: Bot, server: HerdrServer, template: String?, model: String) async throws -> [HerdrHandoffSource] {
        func checkChoice() throws {
            try Task.checkCancellation()
            guard server == herdrServer(for: bot), template == herdrTemplate(for: bot), model == herdrModel(for: bot) else {
                throw BackendError.unavailable("The model choice changed while preparing this message. Send it again to use the new choice.")
            }
        }
        try checkChoice()
        let skipsCarry = herdrMoveSkipsCarry(bot)
        let modelPending = modelSwitchPending(bot)
        let autoPending = autoSwitchPending(bot)
        let pending = modelPending || autoPending
        let client = try herdrClient(for: server)
        let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        do {
            let current = try await client.workspace()
            if let agent = client.liveAgent(named: name, in: current) {
                let staleAuto = agent.autoRestartPending == true && current.program(of: agent) == "Codex"
                if !pending && !staleAuto && template == nil && model.isEmpty {
                    try checkChoice()
                    return [grokHandoffSource(for: bot), herdrCarrySource(for: bot)].compactMap { $0 }
                }
                guard let target = HerdrAgentReading.template(own: template, shared: nil, in: current.templates.filter { $0.error == nil }).template else {
                    throw HerdrClient.Failure.noTemplate
                }
                var replace = autoPending || staleAuto || (target.name != agent.template && (agent.template != nil || modelPending))
                var liveModel: HerdrClient.Template.Model?
                if !replace, target.takesModel, modelPending || !model.isEmpty {
                    guard let reading = await refreshHerdrAgentReading(for: bot, requireFresh: true), reading.session == agent.ref, reading.core == current.core else {
                        throw BackendError.unavailable("The running agent changed while checking its model. Please retry the message.")
                    }
                    liveModel = reading.model
                    if case .model(let active, _) = reading.running { replace = reading.model.map { $0.id != active } ?? modelPending }
                    else { replace = modelPending || (reading.running == .unstated && reading.model != nil) }
                }
                if replace {
                    // Use the exact launch, never an agent found again by name after an asynchronous read.
                    let live = try await client.workspace()
                    try checkChoice()
                    guard live.core == current.core else { throw BackendError.unavailable("The workspace restarted during the model switch. Retry the message.") }
                    let active = client.liveAgent(named: name, in: live)
                    if let active {
                        guard active.ref == agent.ref else { throw BackendError.unavailable("Another session started during the model switch. Retry the message.") }
                        guard active.isIdleForRollover, !herdrAgentIsBusy(active, in: live.agents),
                              !herdrHasUnansweredHelpers(bot, parent: active.ref) else {
                            throw HerdrClient.Failure.notDelivered("The existing session is busy. The saved choice will apply at a safe launch.")
                        }
                        guard try await client.approvals(for: name).isEmpty else {
                            throw HerdrClient.Failure.notDelivered("Review the existing session’s approval before switching.")
                        }
                    }
                    // Auto mode is set in the process environment at launch, so OpenCode cannot apply it in place.
                    if !autoPending, active != nil, target.name == agent.template, target.modelAgent == "OpenCode", let core = current.core, let liveModel {
                        _ = try await client.selectModel(liveModel.id, for: agent.ref, core: core)
                        try checkChoice()
                        rememberModel(.init(server: server.id, core: core, address: agent.address, created: agent.createdMs,
                                            id: liveModel.id, label: HerdrAgentReading.name(liveModel)), for: bot)
                        clearModelSwitch(bot.id)
                        setHerdrMoveSkipsCarry(false, for: bot)
                        return [grokHandoffSource(for: bot), herdrCarrySource(for: bot)].compactMap { $0 }
                    }
                    // Save the handoff before ending the old launch, so an interrupted start can resume it.
                    let old = current.core.map { HerdrAgentLaunch(server: server.id, core: $0, address: agent.address, createdMs: agent.createdMs) }
                    if !skipsCarry { setHerdrCarryOver(HerdrCarryOver(old: old, at: now()), for: bot) }
                    try checkChoice()
                    if active != nil {
                        guard let core = current.core else { throw HerdrClient.Failure.noTemplate }
                        do { try await client.endIfIdle(agent, core: core) }
                        catch {
                            let latest = try await client.workspace()
                            guard latest.core == current.core, client.liveAgent(named: name, in: latest) == nil else { throw error }
                        }
                    }
                    try checkChoice()
                    herdrReadiness[bot.id] = nil
                }
            } else if pending, !skipsCarry, herdrCarryOver(for: bot) == nil, !bot.messages.isEmpty {
                setHerdrCarryOver(HerdrCarryOver(old: nil, at: now()), for: bot)
            }
            try checkChoice()
            clearModelSwitch(bot.id)
            clearAutoSwitch(bot.id)
            setHerdrMoveSkipsCarry(false, for: bot)
        }
        return [grokHandoffSource(for: bot), herdrCarrySource(for: bot)].compactMap { $0 }
    }
}

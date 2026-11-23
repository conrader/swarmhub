import Foundation

extension AppStore {
    func modelSwitchPending(_ bot: Bot) -> Bool { defaults.bool(forKey: "herdr.changeOnSend.\(bot.id)") }

    func markModelSwitch(_ bot: Bot) { defaults.set(true, forKey: "herdr.changeOnSend.\(bot.id)") }

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
        let pending = modelSwitchPending(bot)
        let client = try herdrClient(for: server)
        let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        if pending || template != nil || !model.isEmpty {
            let current = try await client.workspace()
            if let agent = client.liveAgent(named: name, in: current) {
                guard let target = HerdrAgentReading.template(own: template, shared: nil, in: current.templates.filter { $0.error == nil }).template else {
                    throw HerdrClient.Failure.noTemplate
                }
                var replace = target.name != agent.template && (agent.template != nil || pending)
                var liveModel: HerdrClient.Template.Model?
                if !replace, target.takesModel, pending || !model.isEmpty {
                    guard let reading = await refreshHerdrAgentReading(for: bot, requireFresh: true), reading.session == agent.ref, reading.core == current.core else {
                        throw BackendError.unavailable("The running agent changed while checking its model. Please retry the message.")
                    }
                    liveModel = reading.model
                    if case .model(let active, _) = reading.running { replace = reading.model.map { $0.id != active } ?? pending }
                    else { replace = pending || (reading.running == .unstated && reading.model != nil) }
                }
                if replace {
                    // Use the exact launch, never an agent found again by name after an asynchronous read.
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(90))
                    var stillRunning = true
                    while true {
                        let live = try await client.workspace()
                        try checkChoice()
                        guard live.core == current.core else { throw BackendError.unavailable("The workspace restarted during the model switch. Retry the message.") }
                        guard let active = client.liveAgent(named: name, in: live) else { stillRunning = false; break }
                        guard active.ref == agent.ref else { throw BackendError.unavailable("Another session started during the model switch. Retry the message.") }
                        if ["idle", "done"].contains(active.status?.state ?? "") || active.warm == true && active.status?.state == nil && active.ready != false {
                            break
                        }
                        guard clock.now < deadline else { throw BackendError.unavailable("The previous agent is still busy. Your model choice is saved. Retry when it finishes.") }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    if stillRunning, target.name == agent.template, target.modelAgent == "OpenCode", let core = current.core, let liveModel {
                        _ = try await client.selectModel(liveModel.id, for: agent.ref, core: core)
                        try checkChoice()
                        rememberModel(.init(server: server.id, core: core, address: agent.address, created: agent.createdMs,
                                            id: liveModel.id, label: HerdrAgentReading.name(liveModel)), for: bot)
                        defaults.removeObject(forKey: "herdr.changeOnSend.\(bot.id)")
                        return [grokHandoffSource(for: bot), herdrCarrySource(for: bot)].compactMap { $0 }
                    }
                    // Save the handoff before ending the old launch, so an interrupted start can resume it.
                    let old = current.core.map { HerdrAgentLaunch(server: server.id, core: $0, address: agent.address, createdMs: agent.createdMs) }
                    setHerdrCarryOver(HerdrCarryOver(old: old, at: now()), for: bot)
                    try checkChoice()
                    if stillRunning {
                        do { try await client.end(agent) }
                        catch {
                            let latest = try await client.workspace()
                            guard latest.core == current.core, client.liveAgent(named: name, in: latest) == nil else { throw error }
                        }
                    }
                    try checkChoice()
                    herdrReadiness[bot.id] = nil
                }
            } else if pending, herdrCarryOver(for: bot) == nil, !bot.messages.isEmpty {
                setHerdrCarryOver(HerdrCarryOver(old: nil, at: now()), for: bot)
            }
            try checkChoice()
            defaults.removeObject(forKey: "herdr.changeOnSend.\(bot.id)")
        }
        return [grokHandoffSource(for: bot), herdrCarrySource(for: bot)].compactMap { $0 }
    }
}

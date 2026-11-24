import Foundation

enum HerdrMoveMapping {
    case matching
    case one(template: String, model: String)
}

struct HerdrServerMoveRecord {
    struct Choice: Equatable {
        let template: String
        let model: String
    }

    struct Change {
        let botID: UUID
        let name: String
        let before: Choice
        let after: Choice
        let projects: [HerdrBotProject]
        let wasMain: Bool
        let isMain: Bool
        let carryOver: AppStore.HerdrCarryOver?
        let sourceLaunch: HerdrAgentLaunch?
        let messageCount: Int
        let skippedCarry: Bool
    }

    let id = UUID()
    let source: HerdrServer
    let destination: HerdrServer
    let changes: [Change]
    let carryHistory: Bool
    let skipped: [String]
    var cleanup = Cleanup()

    struct Cleanup {
        var stopped = 0
        var busy: [String] = []
        var failed: [String] = []
    }
}

enum HerdrMoveError: LocalizedError {
    case serversChanged, sameWorkspace, selectionChanged, aiUnavailable, undoUnavailable, undoBusy, mainChanged, saveFailed

    var errorDescription: String? {
        switch self {
        case .serversChanged: "A server changed while this sheet was open. Open Move Bots again to see the current servers."
        case .sameWorkspace: "Both connections lead to the same Herdr workspace. Choose another destination server."
        case .selectionChanged: "The selected bots changed. Review the bot list and try again."
        case .aiUnavailable: "The selected AI or model is unavailable on the destination server. Go back and check the connection."
        case .undoUnavailable: "A moved bot’s settings changed. This move can no longer be undone as a group."
        case .undoBusy: "A moved bot is still answering. Wait for the reply to finish, then try Undo again."
        case .mainChanged: "The source server already has a new Main bot. Choose None in its Main bot setting before undoing this move."
        case .saveFailed: "Couldn’t save the move. Check that SwarmHub can write to its data folder and try again."
        }
    }
}

extension AppStore {
    func movableHerdrBots(on server: HerdrServer) -> [Bot] {
        herdrBots(on: server).filter { !$0.isReadOnlyArchive && !$0.isDemo }
    }

    func herdrMoveIsBusy(_ bot: Bot) -> Bool {
        herdrStreaming.contains(bot.id) || runningTurns.values.contains { $0.botID == bot.id }
            || herdrPresence(for: bot)?.isActive == true && herdrReadiness[bot.id]?.isStarting != true
            || herdrHelpers[bot.id]?.helpers.contains { $0.isLive && $0.answered != true } == true
    }

    func herdrMoveWorkspace(on server: HerdrServer, key: String? = nil) async throws -> HerdrClient.Workspace {
        let workspace = try await herdrClient(for: server, token: key).workspace()
        guard workspace.core != nil else { throw BackendError.unavailable(HerdrSetupProblem.noCore.line(for: server)) }
        return workspace
    }

    func herdrMoveDefault(in templates: [HerdrClient.Template]) -> HerdrClient.Template? {
        let shared = defaults.string(forKey: HerdrBackend.templateKey)
        return templates.first { $0.name == shared } ?? templates.first
    }

    /// Read both servers first. Apply all eligible bots' settings in one main-actor transaction, then clean up.
    func moveHerdrBots(_ selected: Set<UUID>, from source: HerdrServer, to destination: HerdrServer,
                       mapping: HerdrMoveMapping, carryHistory: Bool, stopIdleAgents: Bool) async throws -> HerdrServerMoveRecord {
        try checkHerdrMoveServers(source: source, destination: destination)
        let destinationClient = try herdrClient(for: destination)
        let destinationWorkspace = try await herdrMoveWorkspace(on: destination)
        let templates = destinationWorkspace.templates.filter { $0.error == nil }
        guard let fallback = herdrMoveDefault(in: templates) else { throw HerdrMoveError.aiUnavailable }

        // A failed model discovery still leaves the models published in the template available.
        var offered: [String: [HerdrClient.Template.Model]] = [:]
        let templatesToRead: [HerdrClient.Template]
        let explicit: HerdrClient.Template?
        switch mapping {
        case .matching:
            explicit = nil
            templatesToRead = templates
        case .one(let name, _):
            guard let template = templates.first(where: { $0.name == name }) else { throw HerdrMoveError.aiUnavailable }
            explicit = template
            templatesToRead = [template]
        }
        for template in templatesToRead where template.takesModel {
            offered[template.name] = (try? await destinationClient.models(for: template)) ?? template.models ?? []
        }
        if case .one(_, let model) = mapping, let explicit, explicit.takesModel,
           model != HerdrModelChoice.recommended, model != "",
           offered[explicit.name]?.contains(where: { $0.id == model }) != true,
           !(explicit.modelAgent?.caseInsensitiveCompare("OpenCode") == .orderedSame && HerdrModelChoice.apiModelID(model) == model) {
            throw HerdrMoveError.aiUnavailable
        }

        let sourceClient = try? herdrClient(for: source)
        let sourceWorkspace = try? await sourceClient?.workspace()
        if let core = sourceWorkspace?.core, core == destinationWorkspace.core { throw HerdrMoveError.sameWorkspace }
        try Task.checkCancellation()
        try checkHerdrMoveServers(source: source, destination: destination)
        let targets = movableHerdrBots(on: source).filter { selected.contains($0.id) }
        guard !selected.isEmpty, targets.count == selected.count,
              targets.allSatisfy({ !herdrMovesCleaning.contains($0.id) }) else { throw HerdrMoveError.selectionChanged }

        var skipped: [String] = []
        var mainAvailable = herdrMainBot(on: destination) == nil
        var names: [UUID: [String]] = [:]
        var warmStarts: [Task<Void, Never>] = []
        let changes = targets.compactMap { bot -> HerdrServerMoveRecord.Change? in
            let agentNames = herdrExistingAgentNames(for: bot)
            let agents = sourceWorkspace.map { moveAgents(named: agentNames, in: $0) } ?? []
            guard !herdrMoveIsBusy(bot), !agents.contains(where: { moveAgentIsBusy($0, in: sourceWorkspace?.agents ?? []) }) else {
                skipped.append(bot.name)
                return nil
            }

            let before = herdrMoveChoice(for: bot)
            let match = matchingMoveTemplate(for: bot, source: sourceWorkspace?.templates ?? [], destination: templates)
            let template = explicit ?? match ?? fallback
            let model: String
            if !template.takesModel { model = "" }
            else if case .one(_, let chosen) = mapping { model = chosen }
            else if match != nil, offered[template.name]?.contains(where: { $0.id == before.model }) == true { model = before.model }
            else { model = HerdrModelChoice.recommended }
            let isMain = bot.canManageBots && mainAvailable
            if isMain { mainAvailable = false }
            names[bot.id] = agentNames
            if let warming = herdrWarming[bot.id] { warmStarts.append(warming) }
            let launch = sourceWorkspace?.core.flatMap { core in
                agents.first { $0.name == agentNames[0] || HerdrClient.suffix(of: $0.name) == HerdrClient.suffix(of: agentNames[0]) }
                    .map { HerdrAgentLaunch(server: source.id, core: core, address: $0.address, createdMs: $0.createdMs) }
            }
            return .init(botID: bot.id, name: bot.name, before: before, after: .init(template: template.name, model: model),
                         projects: herdrProjects(for: bot), wasMain: bot.canManageBots, isMain: isMain,
                         carryOver: herdrCarryOver(for: bot), sourceLaunch: launch, messageCount: bot.messages.count,
                         skippedCarry: herdrMoveSkipsCarry(bot))
        }
        var record = HerdrServerMoveRecord(source: source, destination: destination, changes: changes, carryHistory: carryHistory, skipped: skipped)
        guard !changes.isEmpty else { return record }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        try applyHerdrMoveRoles(changes.compactMap { change in byID[change.botID].map { ($0, change.isMain) } })
        for change in changes {
            guard let bot = byID[change.botID] else { continue }
            applyHerdrMoveChoice(change.after, server: destination, to: bot)
            if carryHistory { armHerdrCarryOver(for: [bot], running: [:]) }
            else { setHerdrCarryOver(nil, for: bot) }
            setHerdrMoveSkipsCarry(!carryHistory, for: bot)
            latestHerdrMoves[bot.id] = record.id
        }
        objectWillChange.send()

        if stopIdleAgents {
            let moving = changes.map(\.botID)
            herdrMovesCleaning.formUnion(moving)
            defer { herdrMovesCleaning.subtract(moving) }
            for task in warmStarts { await task.value }
            record.cleanup = await cleanHerdrMove(record, client: sourceClient, names: names)
        }
        return record
    }

    /// Restores every bot together. If the move is no longer the latest change, leave the whole batch as it is.
    func undoHerdrMove(_ record: HerdrServerMoveRecord) throws {
        try checkHerdrMoveServers(source: record.source, destination: record.destination)
        let current = movableHerdrBots(on: record.destination)
        let targets = try record.changes.map { change in
            guard let bot = current.first(where: { $0.id == change.botID }), latestHerdrMoves[bot.id] == record.id,
                  herdrMoveChoice(for: bot) == change.after, herdrProjects(for: bot).isEmpty, bot.canManageBots == change.isMain else {
                throw HerdrMoveError.undoUnavailable
            }
            guard !herdrMovesCleaning.contains(bot.id), !herdrMoveIsBusy(bot) else { throw HerdrMoveError.undoBusy }
            return (bot, change)
        }
        if record.changes.contains(where: \.wasMain), herdrMainBot(on: record.source) != nil { throw HerdrMoveError.mainChanged }
        try applyHerdrMoveRoles(targets.map { ($0, $1.wasMain) })
        for (bot, change) in targets {
            applyHerdrMoveChoice(change.before, server: record.source, to: bot)
            setHerdrProjects(change.projects, for: bot)
            if let previous = change.carryOver { setHerdrCarryOver(previous, for: bot) }
            else if record.carryHistory {
                let launch = bot.messages.count == change.messageCount ? change.sourceLaunch : nil
                armHerdrCarryOver(for: [bot], running: launch.map { [bot.id: $0] } ?? [:])
            } else { setHerdrCarryOver(nil, for: bot) }
            setHerdrMoveSkipsCarry(change.skippedCarry || !record.carryHistory && change.carryOver == nil, for: bot)
            latestHerdrMoves[bot.id] = nil
        }
        objectWillChange.send()
    }

    private func checkHerdrMoveServers(source: HerdrServer, destination: HerdrServer) throws {
        guard persistenceEnabled else { throw HerdrMoveError.saveFailed }
        guard source.id != destination.id, herdrServer(id: source.id) == source, herdrServer(id: destination.id) == destination else {
            throw HerdrMoveError.serversChanged
        }
    }

    private func herdrMoveChoice(for bot: Bot) -> HerdrServerMoveRecord.Choice {
        .init(template: defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? "", model: herdrModel(for: bot))
    }

    private func matchingMoveTemplate(for bot: Bot, source: [HerdrClient.Template], destination: [HerdrClient.Template]) -> HerdrClient.Template? {
        let name = herdrTemplate(for: bot) ?? source.first(where: { $0.error == nil })?.name
        let origin = source.first(where: { $0.name == name }) ?? herdrAgentReadings[bot.id]?.runtime
        func sameProgram(_ candidate: HerdrClient.Template) -> Bool {
            guard let origin else { return candidate.name == name }
            if let harness = origin.runtime?.harness, candidate.runtime?.harness?.caseInsensitiveCompare(harness) == .orderedSame { return true }
            if let program = origin.programName ?? origin.modelAgent {
                return (candidate.programName ?? candidate.modelAgent)?.caseInsensitiveCompare(program) == .orderedSame
            }
            return candidate.name == name
        }
        let matches = destination.filter(sameProgram)
        return matches.first { $0.name == name } ?? matches.first
    }

    /// Save role changes with rollback before changing server bindings and runtime caches.
    private func applyHerdrMoveRoles(_ roles: [(Bot, Bool)]) throws {
        let changed = roles.filter { $0.0.canManageBots != $0.1 }
        guard !changed.isEmpty else { return }
        let transaction = SetupTransaction(self)
        for (bot, role) in changed {
            let before = bot.canManageBots
            transaction.record { bot.canManageBots = before }
            bot.canManageBots = role
        }
        do { try transaction.run { try saveThrowing() } }
        catch { throw HerdrMoveError.saveFailed }
    }

    private func applyHerdrMoveChoice(_ choice: HerdrServerMoveRecord.Choice, server: HerdrServer, to bot: Bot) {
        setHerdrServer(server.id, for: bot) // Also clears the old server's project grants and readings.
        setHerdrTemplate(choice.template, for: bot)
        setHerdrModel(choice.model, for: bot)
        clearAutoSwitch(bot.id)
        markModelSwitch(bot)
    }

    private func moveAgents(named names: [String], in workspace: HerdrClient.Workspace) -> [HerdrClient.Agent] {
        guard let direct = names.first else { return [] }
        let groups = Set(names.dropFirst())
        return workspace.agents.filter {
            $0.isLive && $0.parent == nil && (groups.contains($0.name) || $0.name == direct
                || HerdrClient.suffix(of: $0.name) == HerdrClient.suffix(of: direct))
        }
    }

    private func moveAgentIsBusy(_ agent: HerdrClient.Agent, in agents: [HerdrClient.Agent]) -> Bool {
        agent.firstMessage?.sent == false || ["working", "blocked"].contains(agent.status?.state ?? "")
            || agents.contains { $0.isLive && $0.parent == agent.ref && !["idle", "done"].contains($0.status?.state ?? "") }
    }

    private func cleanHerdrMove(_ record: HerdrServerMoveRecord, client: HerdrClient?, names: [UUID: [String]]) async -> HerdrServerMoveRecord.Cleanup {
        var result = HerdrServerMoveRecord.Cleanup()
        guard let client, let workspace = try? await client.workspace(), workspace.core != nil else {
            result.failed = record.changes.map(\.name)
            return result
        }
        for change in record.changes {
            let agents = moveAgents(named: names[change.botID] ?? [], in: workspace)
            guard !agents.isEmpty else { continue }
            var busy = false
            var failed = false
            for agent in agents {
                // Recheck the exact launch immediately before ending it. A new task or helper may have started.
                guard herdrServer(id: record.source.id) == record.source,
                      let current = try? await client.workspace(), current.core == workspace.core else { failed = true; break }
                guard let live = current.agents.first(where: { $0.isLive && $0.ref == agent.ref }) else { continue }
                guard !moveAgentIsBusy(live, in: current.agents), live.isIdleForRollover else { busy = true; continue }
                if let bot = bots.first(where: { $0.id == change.botID }), herdrServer(for: bot).id == record.source.id {
                    busy = true
                    continue
                }
                do { try await client.end(live); result.stopped += 1 }
                catch HerdrClient.Failure.http(404, _) { }
                catch { failed = true }
            }
            if busy { result.busy.append(change.name) }
            if failed { result.failed.append(change.name) }
        }
        return result
    }

    static func herdrMoveSkipsCarryKey(_ id: UUID) -> String { "herdr.moveWithoutCarry.\(id)" }

    func herdrMoveSkipsCarry(_ bot: Bot) -> Bool { defaults.bool(forKey: Self.herdrMoveSkipsCarryKey(bot.id)) }

    func setHerdrMoveSkipsCarry(_ skip: Bool, for bot: Bot) {
        let key = Self.herdrMoveSkipsCarryKey(bot.id)
        if skip { defaults.set(true, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

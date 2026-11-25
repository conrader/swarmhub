import Foundation

extension AppStore {
    func takesInitiative(_ bot: Bot) -> Bool {
        defaults.object(forKey: "herdrInitiative.\(bot.id)") as? Bool ?? true
    }

    func setInitiative(_ enabled: Bool, for bot: Bot) {
        defaults.set(enabled, forKey: "herdrInitiative.\(bot.id)")
        objectWillChange.send()
    }

    private func ownedTeam(_ server: HerdrServer) -> Set<String> {
        Set(defaults.stringArray(forKey: "herdrTeamMembers.\(server.id)") ?? [])
    }

    func teamPreviouslyRegistered(_ id: UUID, on server: HerdrServer) -> Bool {
        ownedTeam(server).contains(id.uuidString.lowercased())
    }

    func bridgeCoordinates(_ bot: Bot) -> Bool {
        teamPreviouslyRegistered(bot.id, on: herdrServer(for: bot))
    }

    func startTeamCoordination() {
        guard launchWorkEnabled, persistenceEnabled, teamPolling == nil else { return }
        teamPolling = Task { [weak self] in
            while !Task.isCancelled {
                guard let servers = self?.herdrServers else { return }
                await withTaskGroup(of: Void.self) { group in
                    for server in servers {
                        group.addTask { [weak self] in await self?.syncTeam(server) }
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func syncTeam(_ server: HerdrServer) async {
        do {
            guard try await ensureTeam(server), let client = try? herdrClient(for: server) else { return }
            try await importTeamHistory(client, server: server)
            if teamErrors[server.id] != nil { teamErrors[server.id] = nil }
        } catch {
            let reason = error.localizedDescription
            if teamErrors[server.id] != reason { teamErrors[server.id] = reason }
        }
    }

    func ensureTeam(_ server: HerdrServer) async throws -> Bool {
        guard persistenceEnabled else { return false }
        if let task = teamRegistrations[server.id] { return try await task.value }
        let task = Task { try await registerTeam(server) }
        teamRegistrations[server.id] = task
        defer { teamRegistrations[server.id] = nil }
        return try await task.value
    }

    private func registerTeam(_ server: HerdrServer) async throws -> Bool {
        let local = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        var owned = ownedTeam(server)
        guard !local.isEmpty || !owned.isEmpty else { return false }
        let client = try herdrClient(for: server)
        var members = try local.map { bot in
            var backend = try herdrBackend(for: bot)
            backend.messageNote = nil
            backend.roster = nil
            return HerdrClient.TeamMember(id: bot.id.uuidString.lowercased(), name: String(bot.name.prefix(40)), agentName: backend.agentName,
                template: backend.template ?? "", model: backend.model ?? "", instructions: HerdrClient.plain(backend.launchInstructions ?? "", bytes: 12 * 1024),
                projects: backend.projects.map(\.id), main: herdrMainBot(on: server)?.id == bot.id,
                takesMessages: herdrTakesMessages(bot), takesInitiative: takesInitiative(bot), notifications: bot.notificationsEnabled)
        }
        let desired = members
        if let cached = teamSynced[server.id], cached.0 == desired, now().timeIntervalSince(cached.1) < 300 { return cached.2 }
        if !members.isEmpty {
            // Resolve recommendations from the same catalogue as an ordinary chat launch.
            let workspace = try await client.workspace()
            var offered: [String: [HerdrClient.Template.Model]] = [:]
            for index in members.indices where members[index].model == HerdrModelChoice.recommended || members[index].model.isEmpty {
                let member = members[index]
                guard let template = workspace.templates.first(where: { $0.error == nil && (member.template.isEmpty || $0.name == member.template) }), template.takesModel else { continue }
                if offered[template.name] == nil { offered[template.name] = try await client.models(for: template) }
                let choices = offered[template.name] ?? []
                members[index].model = member.model == HerdrModelChoice.recommended
                    ? HerdrModelChoice.suggested(program: template.modelAgent ?? template.programName, offered: choices)?.id ?? "@provider-default"
                    : HerdrClient.defaultModel(offered: choices) ?? "@provider-default"
            }
            do { try await client.registerTeam(members) }
            catch HerdrClient.Failure.http(404, _) where owned.isEmpty {
                teamSynced[server.id] = (desired, now(), false)
                return false
            }
        }
        let ids = Set(members.map(\.id))
        let key = "herdrTeamMembers.\(server.id)"
        owned.formUnion(ids)
        defaults.set(Array(owned), forKey: key)
        for removed in owned.subtracting(ids).intersection(removedBots[server.id] ?? []) {
            do { let _: HerdrClient.TeamOK = try await client.post("/api/bots/\(removed)/remove", [:]) }
            catch HerdrClient.Failure.http(404, _) { /* Already removed on the bridge. */ }
            owned.remove(removed)
            defaults.set(Array(owned), forKey: key)
        }
        teamSynced[server.id] = (desired, now(), true)
        return true
    }

    private func importTeamHistory(_ client: HerdrClient, server: HerdrServer) async throws {
        let key = "herdrTeamCursor.\(server.id)"
        var cursor = defaults.integer(forKey: key)
        var selectedRead = cursor
        repeat {
            let page: HerdrClient.TeamPage = try await client.get("/api/bots/history?after=\(cursor)&limit=200")
            var changed = false, held = false
            let before = cursor
            for item in page.items {
                if let bot = bots.first(where: { $0.id.uuidString.lowercased() == item.bot && $0.backend == .herdr && herdrServer(for: $0) == server }) {
                    if item.kind == "said", !isIdle(bot) { held = true; continue }
                    let entry = "\(server.id):\(item.id)"
                    let journal = item.journal.map { "\(server.id):\($0)" }
                    let exists = bot.messages.contains { row in
                        row.metadata["herdrTeamEntry"] == entry || journal.map { row.metadata["herdrJournal"]?.split(separator: " ").contains(Substring($0)) == true } == true
                    }
                    if !exists {
                        var metadata = ["herdrTeamEntry": entry]
                        if let journal { metadata["herdrJournal"] = journal }
                        if item.kind == "message", let exchange = item.message { metadata["herdrExchangeTitle"] = exchange.title }
                        let row = ChatMessage(role: item.kind == "said" ? .assistant : .system, content: item.text,
                            createdAt: Date(timeIntervalSince1970: Double(item.atMs) / 1000), metadata: metadata)
                        let index = bot.messages.firstIndex { $0.transcriptDate > row.transcriptDate } ?? bot.messages.endIndex
                        bot.messages.insert(row, at: index)
                        if item.unread, selectedGroup != nil || selectedBot?.id != bot.id { bot.unreadCount += 1 }
                        if item.notify { notifyIfNeeded(bot: bot, message: item.text) }
                        if item.kind == "said", item.code != "direct_followup", createsHerdrBots(bot) { herdrReplyEnded(row, from: bot, finished: true) }
                        changed = true
                    }
                    if selectedGroup == nil, selectedBot?.id == bot.id { selectedRead = max(selectedRead, item.id) }
                }
                if !held { cursor = item.id }
            }
            if changed || turns.saveFailing { save() }
            guard !turns.saveFailing else { return }
            if cursor != before { defaults.set(cursor, forKey: key) }
            if held || !page.more || cursor != page.items.last?.id { break }
        } while !Task.isCancelled
        let readThrough = max(cursor, selectedRead)
        if let bot = selectedBot, selectedGroup == nil, bot.backend == .herdr, herdrServer(for: bot) == server, isIdle(bot), readThrough > 0 {
            let readKey = "herdrTeamRead.\(server.id).\(bot.id)"
            if readThrough > defaults.integer(forKey: readKey) {
                let _: HerdrClient.TeamOK = try await client.post("/api/bots/\(bot.id.uuidString.lowercased())/read", ["through": readThrough])
                defaults.set(readThrough, forKey: readKey)
            }
        }
    }
}

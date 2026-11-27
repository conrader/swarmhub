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

    private func savePendingMembers(_ ids: Set<String>, key: String) {
        if ids.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(Array(ids), forKey: key) }
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
        // A poll and a first send share the writes. After waiting, check the current roster.
        // A bot may have been added or promoted while the earlier request was in flight.
        while let task = teamRegistrations[server.id] { _ = try await task.value }
        let local = herdrBots(on: server).filter { !$0.isReadOnlyArchive }
        let owned = ownedTeam(server)
        let pendingKey = "herdrTeamPendingMembers.\(server.id)"
        let partialKey = "herdrTeamPartialRegistration.\(server.id)"
        let pending = Set(defaults.stringArray(forKey: pendingKey) ?? [])
        guard !local.isEmpty || !owned.isEmpty || !pending.isEmpty else { return false }
        let main = herdrMainBot(on: server)?.id
        let members = try local.map { bot in
            var backend = try herdrBackend(for: bot)
            backend.messageNote = nil
            backend.roster = nil
            // The bridge limits decoded instructions independently of its JSON body limit.
            let instructions = HerdrClient.plain(backend.launchInstructions ?? "", bytes: 12 * 1024)
            return HerdrClient.TeamMember(id: bot.id.uuidString.lowercased(), name: String(bot.name.prefix(40)), agentName: backend.agentName,
                template: backend.template ?? "", model: backend.model ?? "", instructions: instructions,
                projects: backend.projects.map(\.id), main: main == bot.id,
                takesMessages: herdrTakesMessages(bot), takesInitiative: takesInitiative(bot), notifications: bot.notificationsEnabled)
        }
        let ids = Set(members.map(\.id))
        let removals = owned.union(pending).subtracting(ids).intersection(removedBots[server.id] ?? [])
        if pending.isDisjoint(with: ids), removals.isEmpty, let cached = teamSynced[server.id],
           cached.0 == members, now().timeIntervalSince(cached.1) < 300 { return cached.2 }

        // A partial write also invalidates a previous success if the user later reverts an edit.
        teamSynced[server.id] = nil
        let task = Task {
            defer { teamRegistrations[server.id] = nil }
            let client = try herdrClient(for: server)
            var outstanding = pending
            let batches = try await teamBatches(members, client: client)
            for (index, batch) in batches.enumerated() {
                // On a lost response the bridge may have committed. Remember which local IDs
                // might need explicit removal, without enabling coordinated chat for them yet.
                let added = Set(batch.ids).subtracting(owned).subtracting(outstanding)
                if !added.isEmpty {
                    outstanding.formUnion(added)
                    savePendingMembers(outstanding, key: pendingKey)
                }
                do { try await client.registerTeam(batch) }
                catch let failure as HerdrClient.Failure {
                    if case .http(404, _) = failure, index == 0, owned.isEmpty, !defaults.bool(forKey: partialKey) {
                        // A lost first response left uncertain IDs. No batch was acknowledged,
                        // and this bridge has no directory, so resume legacy coordination.
                        defaults.removeObject(forKey: pendingKey)
                        teamSynced[server.id] = (members, now(), false)
                        if teamErrors[server.id] != nil { teamErrors[server.id] = nil }
                        return false
                    }
                    // The router and its transactional handler make these definitive refusals.
                    switch failure {
                    case .unauthorized, .refusedHost, .http(400..<500, _):
                        outstanding.subtract(added)
                        savePendingMembers(outstanding, key: pendingKey)
                    default: break
                    }
                    throw failure
                }
                // Even on the next attempt, a 404 after an acknowledged upsert is a sync error.
                if index == 0 && owned.isEmpty { defaults.set(true, forKey: partialKey) }
            }
            var forgotten = Set<String>()
            for removed in removals.sorted() {
                // A restore or move can change local membership while the upserts are in flight.
                guard removedBots[server.id]?.contains(removed) == true,
                      !herdrBots(on: server).contains(where: { !$0.isReadOnlyArchive && $0.id.uuidString.lowercased() == removed }) else { continue }
                do { let _: HerdrClient.TeamOK = try await client.post("/api/bots/\(removed)/remove", [:]) }
                catch HerdrClient.Failure.http(404, _) { /* Already removed on the bridge. */ }
                forgotten.insert(removed)
            }
            defaults.set(Array(owned.union(ids).subtracting(forgotten)), forKey: "herdrTeamMembers.\(server.id)")
            outstanding.subtract(ids.union(forgotten))
            savePendingMembers(outstanding, key: pendingKey)
            defaults.removeObject(forKey: partialKey)
            teamSynced[server.id] = (members, now(), true)
            return true
        }
        teamRegistrations[server.id] = task
        return try await task.value
    }

    private func teamBatches(_ desired: [HerdrClient.TeamMember], client: HerdrClient) async throws -> [HerdrClient.TeamRegistrationBatch] {
        guard !desired.isEmpty else { return [] }
        var members = desired
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
        return try HerdrClient.teamRegistrationBatches(members)
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
                    let existing = bot.messages.first { row in
                        row.metadata["herdrTeamEntry"] == entry || journal.map { row.metadata["herdrJournal"]?.split(separator: " ").contains(Substring($0)) == true } == true
                    }
                    let publication = item.journal.flatMap { id in item.page.map { HerdrPublishedResult(page: $0, journalID: id) } }
                    let followup = item.code == "direct_followup" || item.code == "routine_result"
                    if let row = existing {
                        if let publication, row.publishedResults?.serverID == server.id || row.publishedResults == nil {
                            var results = row.publishedResults ?? HerdrReplyResults(serverID: server.id, items: [])
                            if !results.items.contains(where: { $0.pageID == publication.pageID && $0.revision == publication.revision && $0.excerpt != nil }) {
                                results.items.removeAll { $0.pageID == publication.pageID && $0.revision == publication.revision }
                                results.items.append(publication)
                                row.publishedResults = results
                                changed = true
                            }
                        }
                    } else {
                        var metadata = ["herdrTeamEntry": entry]
                        if let journal { metadata["herdrJournal"] = journal }
                        if item.kind == "message", let exchange = item.message { metadata["herdrExchangeTitle"] = exchange.title }
                        let row = ChatMessage(role: item.kind == "said" ? .assistant : .system, content: item.text,
                            createdAt: Date(timeIntervalSince1970: Double(item.atMs) / 1000), metadata: metadata)
                        if let publication {
                            row.publishedResults = HerdrReplyResults(serverID: server.id, items: [publication])
                        }
                        TranscriptHistory.insert(row, into: &bot.messages, server: server.id, entry: item.id,
                            followup: followup, journal: item.journal, receivedAt: now())
                        bot.recoverGoalResult(in: row)
                        if item.unread, !row.isSilent, !showsDirectChat(bot) { bot.unreadCount += 1 }
                        if item.notify { notifyIfNeeded(bot: bot, message: row.content) }
                        if item.kind == "said", !followup, createsHerdrBots(bot) { herdrReplyEnded(row, from: bot, finished: true) }
                        changed = true
                    }
                    if showsDirectChat(bot) { selectedRead = max(selectedRead, item.id) }
                }
                if !held { cursor = item.id }
            }
            if changed || turns.saveFailing { save() }
            guard !turns.saveFailing else { return }
            if cursor != before { defaults.set(cursor, forKey: key) }
            if held || !page.more || cursor != page.items.last?.id { break }
        } while !Task.isCancelled
        let readThrough = max(cursor, selectedRead)
        if let bot = selectedBot, showsDirectChat(bot), bot.backend == .herdr, herdrServer(for: bot) == server, isIdle(bot), readThrough > 0 {
            let readKey = "herdrTeamRead.\(server.id).\(bot.id)"
            if readThrough > defaults.integer(forKey: readKey) {
                let _: HerdrClient.TeamOK = try await client.post("/api/bots/\(bot.id.uuidString.lowercased())/read", ["through": readThrough])
                defaults.set(readThrough, forKey: readKey)
            }
        }
    }
}

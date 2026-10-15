import Foundation

extension AppStore {
    /// One entry per Hermes server + profile used by a live bot, in sidebar order.
    var usageProfiles: [(server: String, profile: String, bots: [Bot])] {
        var order: [String] = []; var groups: [String: (server: String, profile: String, bots: [Bot])] = [:]
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && !bot.isDemo {
            let server = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
            // P38: the server root and its /v1 are the same profile (the backend accepts both).
            var root = HermesBackend.validatedBaseURL(server)?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? server
            if root.hasSuffix("/v1") { root.removeLast(3) }
            let profile = bot.hermesProfile ?? "default", key = "\(root)|\(profile)"
            if groups[key] == nil { order.append(key); groups[key] = (server, profile, []) }
            groups[key]?.bots.append(bot)
        }
        return order.compactMap { groups[$0] }
    }

    /// P38: the agent's main chat, its reply threads and its session in each group. The deterministic ids also find
    /// sessions the server created when the app did not save the answer.
    func usageSessionIDs(for bot: Bot) -> Set<String> {
        var ids: Set<String> = ["\(sessionNamespace)agentapp_\(bot.id.uuidString.lowercased())"]
        if let id = bot.hermesSessionID { ids.insert(id) }
        for thread in bot.threads {
            ids.insert("\(sessionNamespace)agentapp_thread_\(thread.id.uuidString.lowercased())")
            if let id = thread.hermesSessionID { ids.insert(id) }
            if let id = thread.parentSessionID { ids.insert(id) }
        }
        for group in groups {
            if let id = group.session(for: bot.id) { ids.insert(id) }
            if group.memberIDs.contains(bot.id) { ids.insert(sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)) }
        }
        return ids
    }

    /// P38: the Activity tab's usage for one agent, read from its own profile only (GET). A profile of its own counts
    /// every channel; a shared profile counts this agent's conversations and their lineage. Samples, archives, other
    /// backends and a missing key say why without contacting a server.
    func loadUsage(for bot: Bot) async -> BotUsage {
        if bot.isReadOnlyArchive { return BotUsage(problem: "Imported history has no token usage.") }
        if bot.isDemo || bot.backend == .mock { return BotUsage(problem: "Token usage is not available for sample agents.") }
        guard bot.backend == .hermes else { return BotUsage(problem: "Token usage is not available from \(bot.backend.shortName).") }
        if needsKey(bot) { return BotUsage(problem: "No API key for \(bot.hermesProfile ?? "default").") }
        let entry = usageProfiles.first { $0.bots.contains { $0.id == bot.id } }
        let scope: BotUsage.Scope = (entry?.bots.count ?? 1) > 1 ? .conversations : .profile
        let roots = usageSessionIDs(for: bot)
        var report = BotUsage(scope: scope)
        do {
            guard let backend = try backend(for: bot) as? HermesBackend else { return BotUsage(scope: scope, problem: "Not a Hermes backend.") }
            do {
                let read = try await backend.usageSessions()
                report.sessions = scope == .conversations ? SessionUsage.owned(read.sessions, by: roots) : read.sessions
                report.truncated = read.truncated
            } catch { report.problem = BotInfoCache.describe(error, key: backend.apiKey) }
        } catch { report.problem = error.localizedDescription }
        return report
    }

    /// Usage per profile from `GET /api/sessions` (read-only), all profiles in parallel. A profile without a
    /// readable key or sessions API reports why instead of failing the whole list.
    func loadUsage() async -> [ProfileUsage] {
        var pending: [(index: Int, backend: HermesBackend)] = []
        var rows: [ProfileUsage] = []
        for (index, entry) in usageProfiles.enumerated() {
            var row = ProfileUsage(botNames: entry.bots.map(\.name), profile: entry.profile, server: URL(string: entry.server)?.host ?? entry.server)
            if let bot = entry.bots.first {
                if needsKey(bot) { row.problem = "No API key for \(entry.profile)." }
                else {
                    do {
                        if let backend = try backend(for: bot) as? HermesBackend { pending.append((index, backend)) }
                        else { row.problem = "Not a Hermes backend." }
                    } catch { row.problem = error.localizedDescription }
                }
            }
            rows.append(row)
        }
        let results = await withTaskGroup(of: (Int, Result<([SessionUsage], Bool), Error>).self) { group in
            for item in pending {
                group.addTask {
                    do { let read = try await item.backend.usageSessions(); return (item.index, .success((read.sessions, read.truncated))) }
                    catch { return (item.index, .failure(error)) }
                }
            }
            var collected: [(Int, Result<([SessionUsage], Bool), Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (index, result) in results {
            switch result {
            case .success(let read): rows[index].sessions = read.0; rows[index].truncated = read.1
            case .failure(let error): rows[index].problem = BotInfoCache.describe(error, key: pending.first { $0.index == index }?.backend.apiKey ?? "")
            }
        }
        return rows
    }
}

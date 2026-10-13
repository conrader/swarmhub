import Foundation

extension AppStore {
    /// One entry per Hermes server + profile used by a live bot, in sidebar order.
    var usageProfiles: [(server: String, profile: String, bots: [Bot])] {
        var order: [String] = []; var groups: [String: (server: String, profile: String, bots: [Bot])] = [:]
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && !bot.isDemo {
            let server = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
            let profile = bot.hermesProfile ?? "default", key = "\(server)|\(profile)"
            if groups[key] == nil { order.append(key); groups[key] = (server, profile, []) }
            groups[key]?.bots.append(bot)
        }
        return order.compactMap { groups[$0] }
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

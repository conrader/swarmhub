import Foundation

extension AppStore {
    /// The `BotInfoCache` scope (`baseURL|profile`) of a Hermes bot's connection, built without reading its key.
    func connectionScope(for bot: Bot) -> String? {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive,
              let baseURL = HermesBackend.validatedBaseURL(bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { return nil }
        return "\(baseURL.absoluteString)|\(bot.hermesProfile ?? "default")"
    }

    /// The bot's connection's Hermes version as last read (Overview load or Settings), nil when never read.
    func hermesVersion(for bot: Bot) -> HermesVersionReading? { connectionScope(for: bot).flatMap { botInfo.versions[$0] } }

    /// Reads `/health` for every connection a live bot uses that has no reading yet (`force`: all of them), in parallel.
    func loadHermesVersions(force: Bool = false) async {
        var backends: [HermesBackend] = []
        for entry in usageProfiles {
            guard let bot = entry.bots.first, !needsKey(bot), let backend = try? backend(for: bot) as? HermesBackend else { continue }
            if force || botInfo.versions[BotInfoCache.scope(of: backend)] == nil { backends.append(backend) }
        }
        let cache = botInfo
        await withTaskGroup(of: Void.self) { group in
            for backend in backends { group.addTask { await cache.loadVersion(using: backend, force: force) } }
        }
    }

    /// One line per server for Settings → Account → Connection: its host and the version its connections report
    /// (the first readable one), e.g. "konrad.agenthut.net — Hermes 0.21.7 · works".
    var connectionVersionLines: [(server: String, reading: HermesVersionReading?)] {
        var order: [String] = [], readings: [String: HermesVersionReading] = [:]
        for entry in usageProfiles {
            let host = URL(string: entry.server)?.host ?? entry.server
            if !order.contains(host) { order.append(host) }
            for bot in entry.bots.prefix(1) {
                guard let reading = hermesVersion(for: bot) else { continue }
                if readings[host]?.version == nil { readings[host] = reading }
            }
        }
        return order.map { ($0, readings[$0]) }
    }
}

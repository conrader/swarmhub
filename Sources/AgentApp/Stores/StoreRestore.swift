import Foundation

/// Recovery is offered only when the live store is unavailable. A decision supersedes the snapshots that existed
/// at the time, so a later, independent save failure can still be recovered from a newer backup.
enum StoreRestore {
    static let excludedMarkers = [".tmp", ".partial"]
    static let candidateLimit = 500, maxCandidateBytes = 512 << 20

    struct Offer: Equatable, Identifiable {
        let url: URL; let botNames: [String]; let modified: Date?
        var id: URL { url }
        var botCount: Int { botNames.count }
    }

    static let declinedKey = "storeRestore.declined"
    static func decisionKey(for store: URL) -> String { "storeRestore.resolvedThrough." + store.standardizedFileURL.path }

    static func offer(store: URL, resolvedThrough: Date?, declined: Set<String> = [],
                      limit: Int = candidateLimit, maxBytes: Int = maxCandidateBytes) -> Offer? {
        for url in candidates(for: store).prefix(limit) {
            let modified = date(url)
            guard !declined.contains(url.lastPathComponent), resolvedThrough.map({ modified > $0 }) ?? true,
                  let file = decodeBackup(at: url, maxBytes: maxBytes) else { continue }
            let names = file.bots.filter { !$0.isDemo }.map(\.name)
            guard !names.isEmpty else { continue }
            return Offer(url: url, botNames: names, modified: modified)
        }
        return nil
    }

    static func candidates(for store: URL) -> [URL] {
        let directory = store.deletingLastPathComponent()
        let backups = directory.appending(path: "backups")
        return (files(in: directory, for: store) + files(in: backups, for: store, includeBareName: true))
            .sorted { date($0) > date($1) }
    }

    /// Keep the newest readable recovery copy in each recognized family in each backup folder. Keep newer unreadable
    /// copies for recovery in another version, and keep all copies of a family until a usable replacement is verified.
    static func pruneBackups(for store: URL) {
        var verifiedSets: Set<String> = []
        for url in candidates(for: store).prefix(candidateLimit) {
            guard let family = family(of: url, store: store) else { continue }
            let key = url.deletingLastPathComponent().path + "/" + family
            if verifiedSets.contains(key) {
                try? FileManager.default.removeItem(at: url)
            } else if let file = decodeBackup(at: url), file.bots.contains(where: { !$0.isDemo }) || !file.groups.isEmpty {
                verifiedSets.insert(key)
            }
        }
    }

    private static func family(of url: URL, store: URL) -> String? {
        let name = url.lastPathComponent
        if name == store.lastPathComponent { return name }
        let suffix = name.dropFirst(store.lastPathComponent.count + 1)
        return ["before-herdr-only-", "before-restore-", "corrupt-", "bak-", "backup-", "seed-", "pre-"]
            .first { suffix.hasPrefix($0) }
    }

    private static func files(in directory: URL, for store: URL, includeBareName: Bool = false) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                guard (name.hasPrefix(store.lastPathComponent + ".") || (includeBareName && name == store.lastPathComponent)),
                      !excludedMarkers.contains(where: name.contains),
                      let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }

    private static func decodeBackup(at url: URL, maxBytes: Int = maxCandidateBytes) -> StoreFile? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? StoreFile.decode(data)
    }

    static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

enum StoreRestoreCopy {
    static let sender = "SwarmHub"
    static func question(_ offer: StoreRestore.Offer) -> String {
        let bots = offer.botCount == 1 ? "1 bot" : "\(offer.botCount) bots"
        let when = offer.modified.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "Your live SwarmHub data is unavailable. A backup\(when) contains \(bots) (\(names(offer.botNames))). Restore it?"
    }
    static func restore(_ offer: StoreRestore.Offer) -> String { "Restore backup (\(offer.botCount) \(offer.botCount == 1 ? "bot" : "bots"))" }
    static let skip = "Skip backup"
    static func restored(_ count: Int) -> String { count == 1 ? "Restored 1 bot." : "Restored \(count) bots." }
    static let failed = "That saved data could not be opened by this version. It was left where it was; nothing changed."
    private static func names(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}

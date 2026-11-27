import CryptoKit
import Foundation

enum StoreRestore {
    static let candidateLimit = 500, maxCandidateBytes = 512 << 20

    struct Entry: Equatable, Identifiable {
        let id: UUID
        let name: String
        let kind: String
        let messages: Int
        let archiveLines: Int?
        let expectsArchive: Bool
    }

    struct Offer: Equatable, Identifiable {
        let url: URL
        let digest: SHA256.Digest
        let entries: [Entry]
        let modified: Date?
        var id: URL { url }
        var botNames: [String] { entries.filter { $0.kind != "Group" && $0.kind != "Hidden group" }.map(\.name) }
        var botCount: Int { botNames.count }
    }

    static let declinedKey = "storeRestore.declined"
    static func decisionKey(for store: URL) -> String { "storeRestore.resolvedThrough." + store.standardizedFileURL.path }

    @MainActor static func offer(store: URL, resolvedThrough: Date?, declined: Set<String> = [], hideSamples: Bool = false,
                                limit: Int = candidateLimit, maxBytes: Int = maxCandidateBytes) -> Offer? {
        guard !FileManager.default.fileExists(atPath: store.path) else { return nil }
        let history = GrokHistoryStore(directory: store.deletingLastPathComponent().appending(path: "grok-history"))
        for url in candidates(for: store).prefix(limit) {
            let modified = date(url)
            guard !declined.contains(url.lastPathComponent), resolvedThrough.map({ modified > $0 }) ?? true,
                  let data = try? backupData(at: url, maxBytes: maxBytes),
                  let file = try? snapshot(data, hideSamples: hideSamples) else { continue }
            guard file.bots.contains(where: { !$0.isDemo }) || !file.groups.isEmpty else { continue }
            return Offer(url: url, digest: SHA256.hash(data: data), entries: entries(in: file, history: history), modified: modified)
        }
        return nil
    }

    @MainActor static func entries(in file: StoreFile, history: GrokHistoryStore) -> [Entry] {
        file.bots.map { bot in
            Entry(id: bot.id, name: bot.name, kind: bot.isHidden ? "Hidden bot" : (bot.isReadOnlyArchive ? "Read-only bot" : "Bot"),
                  messages: bot.messages.count, archiveLines: history.lineCountOnDisk(for: bot.id),
                  expectsArchive: bot.grokHistoryCount > 0)
        } + file.groups.map { group in
            Entry(id: group.id, name: group.name, kind: group.isHidden ? "Hidden group" : "Group",
                  messages: group.messages.count, archiveLines: history.lineCountOnDisk(for: group.id),
                  expectsArchive: group.grokHistoryCount > 0)
        }
    }

    static func snapshot(_ data: Data, hideSamples: Bool) throws -> StoreFile {
        var file = try StoreFile.decode(data)
        file.version = StoreFile.currentVersion
        _ = file.migrateArchivedGroups()
        if hideSamples && FirstRun.hasRealAgents(file.bots) { file.bots.filter(\.isDemo).forEach { $0.isHidden = true } }
        // A backup's deletion intents are historical and must not replay on a host.
        file.removedBots = nil
        file.pendingHerdrEndings = nil
        return file
    }

    static func candidates(for store: URL) -> [URL] {
        let directory = store.deletingLastPathComponent()
        let backups = directory.appending(path: "backups")
        return (files(in: directory, for: store) + files(in: backups, for: store, includeBareName: true))
            .sorted { date($0) > date($1) }
    }

    private static func files(in directory: URL, for store: URL, includeBareName: Bool = false) -> [URL] {
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                return (name.hasPrefix(store.lastPathComponent + ".") || (includeBareName && name == store.lastPathComponent))
                    && ![".tmp", ".partial", ".writer-lock"].contains(where: name.contains)
                    && validFile(url, maxBytes: maxCandidateBytes)
            }
    }

    private static func validFile(_ url: URL, maxBytes: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              let size = values.fileSize else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && size <= maxBytes
    }

    static func backupData(at url: URL, maxBytes: Int = maxCandidateBytes) throws -> Data {
        guard validFile(url, maxBytes: maxBytes) else { throw CocoaError(.fileReadUnknown) }
        return try Data(contentsOf: url)
    }

    static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

enum StoreRestoreCopy {
    static let sender = "SwarmHub"
    static func question(_ offer: StoreRestore.Offer) -> String {
        let when = offer.modified.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "Your live SwarmHub data is unavailable. Review the backup\(when) before restoring it."
    }
    static func restore(_ offer: StoreRestore.Offer) -> String { "Restore backup" }
    static let skip = "Keep current data"
    static func restored(_ count: Int) -> String { count == 1 ? "Restored 1 chat." : "Restored \(count) chats." }
    static let failed = "The backup or live data changed. Reopen SwarmHub to review the current data."
}

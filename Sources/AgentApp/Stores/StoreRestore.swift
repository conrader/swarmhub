import Foundation

/// autoctx1: a store.json that could not be read is moved aside as `store.json.corrupt-<stamp>` (and backups may sit next
/// to it). When the store is missing or unreadable, or holds only the bot SwarmHub seeds itself, the newest set-aside file
/// that this build decodes is offered back in a chat-style prompt; nothing is restored or seeded without the user's press.
enum StoreRestore {
    static let seedDescription = "Default Hermes profile"
    /// Files never offered: what a restore set aside itself, and partial writes.
    static let excludedMarkers = [".before-restore-", ".tmp", ".partial"]
    /// Every candidate is tried, newest first, so newer unusable copies never hide an older good one. The bounds only keep
    /// a directory full of junk from stalling launch: at most this many files, none bigger than this.
    static let candidateLimit = 500, maxCandidateBytes = 512 << 20

    struct Offer: Equatable, Identifiable {
        let url: URL; let botNames: [String]; let modified: Date?
        var id: URL { url }
        var botCount: Int { botNames.count }
    }

    /// The offer for this launch, or nil. `current` is what the store holds now (empty when missing or unreadable).
    /// UserDefaults: the set-aside files the user answered "Start fresh" to (file names), never offered again.
    static let declinedKey = "storeRestore.declined"

    static func offer(directory: URL, store: URL, current: [Bot], declined: Set<String> = [], fileManager: FileManager = .default,
                      limit: Int = candidateLimit, maxBytes: Int = maxCandidateBytes) -> Offer? {
        guard current.filter({ !$0.isDemo }).isEmpty || onlySeed(current) else { return nil }
        for url in candidates(directory: directory, store: store, fileManager: fileManager).filter({ !declined.contains($0.lastPathComponent) }).prefix(limit) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maxBytes, let file = try? StoreFile.decode(Data(contentsOf: url)) else { continue }
            let real = file.bots.filter { !$0.isDemo }
            guard !real.isEmpty, !onlySeed(real) else { continue }
            if !current.isEmpty, real.count <= current.filter({ !$0.isDemo }).count { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return Offer(url: url, botNames: real.map(\.name), modified: modified)
        }
        return nil
    }

    /// `store.json.*` siblings (corrupt copies, backups), newest first.
    static func candidates(directory: URL, store: URL, fileManager: FileManager = .default) -> [URL] {
        let name = store.lastPathComponent
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])) ?? []
        return urls.filter { url in
            let file = url.lastPathComponent
            return file.hasPrefix(name + ".") && !excludedMarkers.contains { file.contains($0) }
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }.sorted { date($0) > date($1) }
    }

    /// The single untouched bot a fresh launch seeds (`seedDefaultHermesBot`): nothing typed, no server of its own.
    static func onlySeed(_ bots: [Bot]) -> Bool {
        let real = bots.filter { !$0.isDemo }
        guard real.count == 1, let bot = real.first else { return false }
        return bot.name == "Hermes" && bot.botDescription == seedDescription && bot.hermesProfile == "default"
            && bot.hermesBaseURL == nil && !bot.messages.contains { $0.role == .user }
    }

    private static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

enum StoreRestoreCopy {
    static let sender = "SwarmHub"
    static func question(_ offer: StoreRestore.Offer) -> String {
        let bots = offer.botCount == 1 ? "1 bot" : "\(offer.botCount) bots"
        let when = offer.modified.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "I found your saved SwarmHub data\(when) with \(bots) (\(names(offer.botNames))). It couldn’t be opened last time, so it was set aside. Restore it?"
    }
    static func restore(_ offer: StoreRestore.Offer) -> String { offer.botCount == 1 ? "Restore my bot" : "Restore my \(offer.botCount) bots" }
    static let startFresh = "Start fresh"
    static func restored(_ count: Int) -> String { count == 1 ? "Restored 1 bot." : "Restored \(count) bots." }
    static let failed = "That saved data could not be opened by this version. It was left where it was; nothing changed."
    private static func names(_ names: [String]) -> String {
        names.count <= 4 ? names.joined(separator: ", ") : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}

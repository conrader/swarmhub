import Foundation

/// What this build does with a store.json an older build wrote. Older builds also ran bots on two backends that are
/// gone, and kept more with every bot than this build does (threads, routines, approvals, skills); this build runs
/// Herdr agents only. The first time it opens such a store, the file is copied as it was to a dated backup beside it
/// (`backupURL`) before anything is written. A bot of a removed backend cannot run here, so it is not loaded: the
/// store is saved without those bots and without what only belonged to them (`AppStore.removeLegacyBots`), and the
/// person is told once, in one line, how many bots were removed and where the backup is. Keys this build does not
/// know are ignored, never an error; the saved store no longer has them, so the backup is made once.
enum LegacyStore {
    /// The `backend` values of bots that are left out. Any other unknown value is a decode error, as before: a store
    /// from a newer build is set aside untouched, never trimmed.
    static let removedBackends: Set<String> = ["Hermes Agent", "OpenClaw"]

    /// What older builds saved with a bot and this build does not keep. A bot that has one was written by an older build.
    static let olderBotKeys: Set<String> = ["hermesProfile", "hermesBaseURL", "hermesModelLock", "hermesSessionID", "threads", "routines", "routineRunMarks", "approvalMode", "approvalRules",
        "approvalAudit", "approvalRouting", "reviewAfter", "reviewerBotID", "modelSettings", "boxInstructions", "retiredOnBox", "openClaw", "installedSkills", "installedSkillVariants",
        "skillInstallFailures", "skillBannerSnoozed", "skillDevMode", "skillsModifiedLocally", "grokRoutineIDs", "adoptedKeyBackup", "memorySummary", "skills", "importedMemories",
        "importedSkills", "requestedConnectorIDs", "gettingStartedSkill", "connectorReport", "computerURL", "orientedAt", "orientationQueuedAt"]
    /// The same for the store itself.
    static let olderStoreKeys: Set<String> = ["modelDefaults", "approvalRoutes", "reviewAfter", "boxReadings", "botMessageMarks", "automations", "managedApprovals", "heartbeat"]

    /// Any key, to ask a container which keys it holds.
    struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A bot that was left out: enough to drop what belonged to it and to count it.
    struct RemovedBot: Equatable, Sendable { let id: UUID; let name: String; let backend: String }

    /// One element of the file's `bots`: a bot this build runs, or one it leaves out.
    struct StoredBot: Decodable {
        let bot: Bot?; let removed: RemovedBot?
        /// The bot holds something only an older build saved.
        let isOlder: Bool
        private enum Key: CodingKey { case id, name, backend }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let backend = try c.decode(String.self, forKey: .backend)
            isOlder = try !LegacyStore.olderBotKeys.isDisjoint(with: decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
            if LegacyStore.removedBackends.contains(backend) {
                removed = RemovedBot(id: try c.decode(UUID.self, forKey: .id), name: (try? c.decode(String.self, forKey: .name)) ?? "", backend: backend)
                bot = nil
            } else {
                bot = try Bot(from: decoder); removed = nil
            }
        }
    }

    /// In the name of the one-time backup; `StoreRestore` never offers such a file back.
    static let backupMarker = ".before-herdr-only-"
    /// `UserDefaults`: the line shown until it is dismissed.
    static let noticeKey = "legacyStore.notice"

    /// `store.json.before-herdr-only-2026-11-16T22-10-05Z` beside the store; with that name taken, the same with `-2`, `-3`…
    /// so a backup is never written over.
    static func backupURL(store: URL, now: Date, fileManager: FileManager = .default) -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = store.lastPathComponent + backupMarker + stamp, directory = store.deletingLastPathComponent()
        var url = directory.appending(path: base), number = 2
        while fileManager.fileExists(atPath: url.path) { url = directory.appending(path: "\(base)-\(number)"); number += 1 }
        return url
    }

    /// Writes `original` (the file's bytes as they were read) to the backup, never over an existing file.
    static func writeBackup(_ original: Data, store: URL, now: Date) throws -> URL {
        let url = backupURL(store: store, now: now)
        try original.write(to: url, options: .withoutOverwriting)
        return url
    }

    static func notice(removed: Int, backup: URL) -> String {
        let bots = removed == 1 ? "1 bot from the older version was removed" : "\(removed) bots from the older version were removed"
        return "\(bots): this version runs bots on Herdr only. A copy of your data as it was is in \(backup.path)."
    }

    static let backupFailed = "This store holds bots from an older version that this version cannot run. They could not be backed up, so nothing was changed and saving is off for this launch."
}

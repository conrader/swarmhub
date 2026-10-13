import Foundation
import Security

/// `AgentApp --migrate-store`: loads the real store (which converts P6 archived Grok groups into P5 groups
/// and rewrites store.json in the current format), then prints each group's members — names and counts only.
extension HeadlessCommands {
    static func migrateStore() -> Int32 {
        SecKeychainSetUserInteractionAllowed(false)
        let store = AppStore(autoConfigureHermes: false)
        guard store.persistenceEnabled else { print("Migration failed: \(store.errorMessage ?? "the store cannot be saved.")"); return 1 }
        store.save()
        for line in migrationReport(store) { print(line) }
        return 0
    }

    static func migrationReport(_ store: AppStore) -> [String] {
        var lines = ["Store \(store.fileURL.path): format v\(StoreFile.currentVersion), \(store.bots.count) bots, \(store.groups.count) groups"]
        lines.append(store.migratedGroupNames.isEmpty ? "No archived groups left to migrate." : "Migrated \(store.migratedGroupNames.count) archived group(s): \(store.migratedGroupNames.joined(separator: "; "))")
        lines += groupLines(store)
        return lines
    }

    /// `Group <name> | members: A, B | messages N | archive N | sessions N` per group.
    static func groupLines(_ store: AppStore) -> [String] {
        store.groups.map { group in
            let names = store.members(of: group).map(\.name)
            return "Group \(group.name) | members: \(names.isEmpty ? "none" : names.joined(separator: ", ")) | messages \(group.messages.count) | archive \(group.grokHistoryCount) | sessions \(group.sessions.count)"
        }
    }
}

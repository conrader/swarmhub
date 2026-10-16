import Foundation

/// P51: the names a folded row's line uses in this app: bots by profile, apps from the Composio catalog, P48 account
/// names for account ids.
extension AppStore {
    func technicalContext(botName: String) -> TechnicalContext {
        let apps = connectedApps
        return TechnicalContext(botName: botName, displayName: { [weak self] in self?.displayName(forProfile: $0) ?? $0 },
                                appName: { apps.appName($0) }, accountName: { id in apps.accounts.first { $0.id == id }?.label })
    }

    /// One chat's folds; a group names each reply's author.
    func technicalLayout(_ rows: [ChatMessage], botName: String) -> TechnicalLayout {
        let context = technicalContext(botName: botName)
        return TechnicalRow.layout(rows, context: { _ in context })
    }

    func technicalLayout(_ rows: [ChatMessage], in group: GroupChat) -> TechnicalLayout {
        var contexts: [UUID?: TechnicalContext] = [:]
        return TechnicalRow.layout(rows) { row in
            if let known = contexts[row.authorID] { return known }
            let made = technicalContext(botName: row.authorID.flatMap { id in bots.first { $0.id == id }?.name } ?? group.name)
            contexts[row.authorID] = made
            return made
        }
    }
}

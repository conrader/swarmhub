import Foundation

/// The Done step: what was imported. Counts are read back from the store and the archive files.
extension GrokImportCoordinator {
    /// The installed Grok Bot is newer than the one this import was checked against: its private interface may have moved.
    var versionDriftNote: String? {
        guard let installed = grokVersion,
              installed.compare(GrokProtocol.capturedVersion, options: .numeric) == .orderedDescending else { return nil }
        return "Grok Bot is \(installed); this import was last checked against \(GrokProtocol.capturedVersion)."
    }

    /// Rebuilds the outcome rows from what the store holds now.
    func refreshOutcomes() async {
        outcomes = committedRows.map { row in
            let bot = store.bots.first { $0.grokSourceID == row.sourceID }
            let group = store.groups.first { $0.grokSourceID == row.sourceID }
            let ownerID = row.status == .skipped ? nil : bot?.id ?? group?.id
            return GrokImportOutcome(
                id: row.sourceID, botID: ownerID, name: bot?.name ?? group?.name ?? row.name, isGroup: row.isGroup,
                archiveLines: ownerID.flatMap { store.grokHistory.lineCountOnDisk(for: $0) } ?? 0, row: row)
        }
    }

    /// The bots on the Done step, in import order (groups are in the coverage details).
    var botOutcomes: [GrokImportOutcome] { outcomes.filter { !$0.isGroup && $0.botID != nil } }

    var outcomeHeadline: String {
        let counts = Dictionary(grouping: outcomes, by: { $0.row.status })
        let attempted = Set(outcomes.map(\.id))
        let remaining = progress.filter { !attempted.contains($0.id) }.count
        return "\(counts[.done]?.count ?? 0) imported · \(counts[.incomplete]?.count ?? 0) partial · \((counts[.skipped]?.count ?? 0) + remaining) skipped"
    }

    func savedDestination(for outcome: GrokImportOutcome) -> (location: String, workspace: String?)? {
        guard let id = outcome.botID else { return nil }
        if let bot = store.bots.first(where: { $0.id == id }) {
            let server = store.herdrServer(for: bot)
            let template = store.herdrTemplate(for: bot)
            let offer = destinationPlan?.serverID == server.id ? destinationPlan?.offer : nil
            let program = template.flatMap { offer?.program($0) }
            let model = program.flatMap { HerdrModelChoice.suggested(program: $0.modelAgent ?? $0.name, offered: $0.models) }
            let action = outcome.row.created == true ? "Created bot" : "Updated history"
            let runtime = store.herdrProgramName(for: bot) ?? program?.name ?? template
            let modelName = store.herdrAgentReadings[bot.id]?.short ??
                (store.herdrModel(for: bot) == HerdrModelChoice.recommended ? model.map(HerdrProgram.modelName) : store.herdrModel(for: bot))
            let path = offer?.workspaceRoot.map { $0 + "/" + id.uuidString.lowercased() }
            let location = [action, server.name, runtime, modelName, bot.isHidden ? "Hidden chats" : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (location, path)
        }
        guard let group = store.groups.first(where: { $0.id == id }) else { return nil }
        let action = outcome.row.created == true ? "Created group" : "Updated group history"
        return (group.isHidden ? action + " · Hidden chats" : action, nil)
    }

    func open(_ outcome: GrokImportOutcome) {
        guard let id = outcome.botID else { return }
        if let bot = store.bots.first(where: { $0.id == id }) { store.open(bot) }
        else if let group = store.groups.first(where: { $0.id == id }) { store.open(group) }
        store.showingGrokImport = false
    }

    func selectImportedMainBotIfNeeded() {
        guard destinationPlan != nil else { return }
        if let bot = botOutcomes.compactMap({ row in store.bots.first { $0.id == row.botID } })
            .first(where: { !$0.isHidden && store.herdrServer(for: $0).id == destinationPlan?.serverID }) {
            FirstRun.record(.done, in: store.defaults)
            if !store.hasRealBots || store.selectedBot?.grokSourceID == nil && store.selectedGroup == nil { store.open(bot) }
        }
    }
}

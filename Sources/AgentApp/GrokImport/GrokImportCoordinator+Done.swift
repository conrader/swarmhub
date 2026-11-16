import Foundation

/// The Done step: what was imported. Counts are read back from the store and the archive files.
extension GrokImportCoordinator {
    /// Rebuilds the outcome rows from what the store holds now.
    func refreshOutcomes() async {
        outcomes = committedRows.map { row in
            let bot = store.bots.first { $0.grokSourceID == row.sourceID }
            let group = store.groups.first { $0.grokSourceID == row.sourceID }
            let ownerID = bot?.id ?? group?.id
            return GrokImportOutcome(
                id: row.sourceID, botID: ownerID, name: bot?.name ?? group?.name ?? row.name, isGroup: row.isGroup,
                archiveLines: ownerID.flatMap { store.grokHistory.lineCountOnDisk(for: $0) } ?? 0, row: row)
        }
    }

    /// The bots on the Done step, in import order (groups are in the coverage details).
    var botOutcomes: [GrokImportOutcome] { outcomes.filter { !$0.isGroup } }
}

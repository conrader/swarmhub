import CryptoKit
import Foundation

/// A Grok routine as the importer keeps it: already through the secret filter, and never enabled.
struct GrokStagedRoutine: Sendable, Equatable { var id: String; var name: String; var prompt: String; var schedule: String }

extension AppStore {
    /// Grok routines and connector requests land inert, like a template import's: each routine is a paused,
    /// not-on-server row (`importKind: .cron`; one without a schedule needs setup before "Create on server" shows), and
    /// connectors only join `requestedConnectorIDs`, the suggestions next to this bot's connected-app switches, which
    /// stay off until the user turns one on. Re-importing never duplicates: a routine is keyed by bot and Grok routine id,
    /// its pending row takes the latest name, and one already created on the server or removed never comes back. A
    /// pending row whose routine is gone from the latest import is dropped and its id forgotten (it may return if the
    /// source lists it again). Pending rows have no editor: setting one up moves it to the server, out of `routines`.
    func mergeGrokStaged(_ prepared: PreparedGrokBundle, into bot: Bot) {
        let latest = Set(prepared.routines.map(\.id))
        for gone in bot.grokRoutineIDs.subtracting(latest) {
            let id = Self.grokRoutineUUID(sourceID: prepared.bundle.sourceId, routineID: gone)
            if let index = bot.routines.firstIndex(where: { $0.id == id && $0.importKind == .cron && !$0.isEnabled }) {
                bot.routines.remove(at: index); bot.grokRoutineIDs.remove(gone)
            }
        }
        for routine in prepared.routines {
            let id = Self.grokRoutineUUID(sourceID: prepared.bundle.sourceId, routineID: routine.id)
            if let index = bot.routines.firstIndex(where: { $0.id == id }) {
                bot.routines[index].name = routine.name
                if bot.routines[index].schedule.isEmpty { bot.routines[index].schedule = routine.schedule }
                if bot.routines[index].prompt.isEmpty { bot.routines[index].prompt = routine.prompt }
                bot.routines[index].isEnabled = false
            } else if bot.grokRoutineIDs.insert(routine.id).inserted {
                bot.routines.append(BotRoutine(id: id, name: routine.name, schedule: routine.schedule, prompt: routine.prompt,
                                               isEnabled: false, importKind: .cron))
            }
        }
        for connector in prepared.connectors where !bot.requestedConnectorIDs.contains(connector) {
            bot.requestedConnectorIDs.append(connector)
        }
    }

    /// The same UUID for the same bot and Grok routine on every import.
    nonisolated static func grokRoutineUUID(sourceID: String, routineID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("grok-routine|\(sourceID)|\(routineID)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50; bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Drops a routine that is not on the server yet; an imported Grok one stays remembered, so it is not re-added.
    func removePendingRoutine(_ routine: BotRoutine, from bot: Bot) {
        bot.routines.removeAll { $0.id == routine.id }
        objectWillChange.send(); save()
    }
}

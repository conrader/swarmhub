import AppKit
import Foundation

/// P38 D: one routine run's card as the ledger keeps it (kind `routineDelivery`, id `bot|job|session or run time`). The
/// record is written before the card reaches the chat or a notification, so a crash in between neither loses the run
/// nor posts it twice. A timestamp-only card that a later read completes is retired (`supersededBy`), not repeated.
struct RoutineDelivery: Codable {
    var id: String
    var botID: UUID
    var message: ChatMessage
    var delivered = false
    var notified = false
    var supersededBy: String?
}

/// P38 D: "pause it again after this run" for a Run now on a paused job, kept across a relaunch (kind `routineRepause`).
struct RoutineRepause: Codable {
    var id: String
    var on: Bool
}

extension AppStore {
    static let routineDeliveryKind = "routineDelivery", routineRepauseKind = "routineRepause"

    /// Launch: every committed card is in its bot's chat exactly once; retired placeholders are removed.
    func restoreRoutineDeliveries() {
        guard persistenceEnabled, hasLedger else { return }
        do {
            var changed = false
            for record in try journal().records(RoutineDelivery.self, kind: Self.routineDeliveryKind) {
                guard let bot = bots.first(where: { $0.id == record.botID }) else { continue }
                if record.supersededBy != nil {
                    let count = bot.messages.count
                    bot.messages.removeAll { $0.metadata["deliveryKey"] == record.id }
                    changed = changed || count != bot.messages.count
                } else if let existing = bot.messages.first(where: { $0.metadata["deliveryKey"] == record.id }) {
                    if existing.content != record.message.content || existing.metadata != record.message.metadata {
                        existing.content = record.message.content; existing.metadata = record.message.metadata; changed = true
                    }
                } else { bot.messages.append(record.message); changed = true }
            }
            for record in try journal().records(RoutineRepause.self, kind: Self.routineRepauseKind) where record.on { routines.repauseAfterRun.insert(record.id) }
            if changed { save() }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Records the repause intent in memory and, when the ledger is available, on disk.
    func setRepause(_ on: Bool, key: String) {
        if on { routines.repauseAfterRun.insert(key) } else { routines.repauseAfterRun.remove(key) }
        guard persistenceEnabled, on || hasLedger else { return }
        do { try journal().put(RoutineRepause(id: key, on: on), kind: Self.routineRepauseKind, id: key) } catch { errorMessage = error.localizedDescription }
    }

    /// Posts (or completes) the card for one run. Without a ledger (a window that does not save) the card is posted directly.
    func deliverRoutine(_ job: HermesJob, result: HermesRunResult?, bot: Bot, lookupError: String?, notify: Bool = true) throws {
        let key = "\(bot.id)|\(job.id)|\(result?.sessionID ?? job.lastRunAt ?? "unknown")"
        let card = Self.routineCard(job: job, result: result, lookupError: lookupError)
        card.metadata["deliveryKey"] = key
        guard persistenceEnabled else { project(card, key: key, aliases: [], bot: bot, notify: notify && result != nil, job: job); return }
        let journal = try journal()
        let records = try journal.records(RoutineDelivery.self, kind: Self.routineDeliveryKind)
        // A stale poll without output never replaces a card that already has the run's session.
        if result == nil, records.contains(where: { $0.botID == bot.id && $0.supersededBy == nil && $0.message.metadata["jobID"] == job.id
            && $0.message.metadata["sessionID"] != nil && Self.sameRoutineRun($0.message.metadata["runAt"], job.lastRunAt) }) { return }
        var record = records.first(where: { $0.id == key }) ?? RoutineDelivery(id: key, botID: bot.id, message: card)
        let aliases = records.filter {
            $0.id != key && $0.botID == bot.id && $0.supersededBy == nil && $0.message.metadata["jobID"] == job.id
                && Self.sameRoutineRun($0.message.metadata["runAt"], job.lastRunAt) && $0.message.metadata["sessionID"] == nil
        }
        record.message = card
        let shouldNotify = notify && result != nil && !record.notified
        record.notified = record.notified || shouldNotify; record.delivered = true
        let retired = aliases.map { previous -> (id: String, value: RoutineDelivery) in
            var previous = previous; previous.supersededBy = key; return (previous.id, previous)
        }
        // Intent first: the full result, the retired placeholders and the notification mark commit together.
        try journal.putMany(retired + [(key, record)], kind: Self.routineDeliveryKind)
        project(card, key: key, aliases: Set(aliases.map(\.id)), bot: bot, notify: shouldNotify, job: job)
    }

    private func project(_ card: ChatMessage, key: String, aliases: Set<String>, bot: Bot, notify: Bool, job: HermesJob) {
        if let existing = bot.messages.first(where: { $0.metadata["deliveryKey"] == key || aliases.contains($0.metadata["deliveryKey"] ?? "") }) {
            existing.content = card.content; existing.metadata = card.metadata
            bot.messages.removeAll { $0.id != existing.id && aliases.contains($0.metadata["deliveryKey"] ?? "") }
        } else {
            bot.messages.append(card)
            if selectedBot?.id != bot.id || NSApp?.isActive != true { bot.unreadCount += 1 }
        }
        objectWillChange.send(); save()
        if notify { notifyIfNeeded(bot: bot, message: "Routine finished: \(job.name)" + (card.content.isEmpty ? "" : " — \(card.content)")) }
    }

    /// Runs that finished after `seen` other than the newest one (which gets its own card), oldest first. Each gets a
    /// card without a notification. A failed read leaves one line in the routines pane; the newest card still comes.
    func catchUpRoutine(_ job: HermesJob, after seen: String, bot: Bot, client: HermesJobsClient) async -> [(job: HermesJob, result: HermesRunResult)] {
        do {
            let runs = try await client.completedRuns(for: job, after: seen)
            return runs.dropLast().map { entry in
                var finished = job; finished.lastRunAt = entry.stamp
                finished.lastStatus = entry.result.status ?? "ok"; finished.lastError = entry.result.error
                return (finished, entry.result)
            }
        } catch {
            routines.update(bot.id) { $0.error = "Earlier runs of \(job.name) could not be read: \(BotInfoCache.describe(error, key: client.backend.apiKey))" }
            return []
        }
    }

    static func sameRoutineRun(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        guard let left = RoutineTime.date(lhs), let right = RoutineTime.date(rhs) else { return false }
        return left == right
    }
}

import CryptoKit
import Foundation

/// Identifies the request as the workspace saved it, including any launch instructions,
/// without copying those instructions into the transcript again.
struct HerdrDeliveryReceipt: Codable, Equatable, Sendable {
    let server, core, address: String
    let createdMs: UInt64
    let after: Int
    let taskDigest: Data

    init(server: String, turn: HerdrClient.Turn, text: String) {
        self.server = server
        core = turn.core
        address = turn.address
        createdMs = turn.createdMs
        after = turn.after
        taskDigest = Self.digest(text)
    }

    private static func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    enum Outcome {
        case waiting, unresolved
        case answered(HerdrClient.Item, [HerdrPublishedResult])
    }

    func resolve(_ items: [HerdrClient.Item]) -> Outcome {
        let rows = items.filter { $0.id > after }.sorted { $0.id < $1.id }
        guard let task = rows.firstIndex(where: { $0.kind == "task" }) else { return .waiting }
        guard rows[task].reachedAgent, Self.digest(rows[task].text) == taskDigest else { return .unresolved }
        let following = rows.suffix(from: task + 1)
        // Two writers may have sent identical text after the same cursor.
        guard !following.contains(where: { $0.reachedAgent && Self.digest($0.text) == taskDigest }) else { return .unresolved }
        var results: [HerdrPublishedResult] = []
        for item in following {
            if item.reachedAgent { return .unresolved }
            if item.kind == "reply", item.replyTo == nil, item.answerTo.map({ $0.id == rows[task].id }) ?? true,
               !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .answered(item, results)
            }
            if let result = HerdrPublishedResult(item) { results.append(result) }
        }
        return .waiting
    }

    func read(from client: HerdrClient) async throws -> Outcome {
        var items: [HerdrClient.Item] = []
        var before: Int?
        repeat {
            try Task.checkCancellation()
            let page = try await client.historyPage(core: core, address: address, createdMs: createdMs, before: before)
            items.append(contentsOf: page.items)
            guard let next = page.before, next > after else { break }
            guard before.map({ next < $0 }) ?? true else { return .unresolved }
            before = next
        } while true
        return resolve(items)
    }
}

extension AppStore {
    func recoverAcceptedDirectReplies() {
        for bot in bots where bot.backend == .herdr && !bot.isReadOnlyArchive {
            for row in bot.messages where row.turnState == .incomplete {
                guard let receipt = row.deliveryReceipt else { continue }
                row.checkingSavedReply = true
                Task { [weak self, weak bot, weak row] in
                    defer { row?.checkingSavedReply = false }
                    var delay = 2
                    while let self, let bot, let row, !Task.isCancelled {
                        guard await self.checkRecoveredReply(receipt, bot: bot, row: row) else { return }
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        delay = min(delay * 2, 30)
                    }
                }
            }
        }
    }

    /// Recheck ownership after network I/O. A chat can be removed, moved or stopped while offline.
    func checkRecoveredReply(_ receipt: HerdrDeliveryReceipt, bot: Bot, row: ChatMessage) async -> Bool {
        let server = herdrServer(for: bot)
        func current() -> Bool {
            storeRestoreOffer == nil && bots.contains { $0 === bot } && bot.backend == .herdr && !bot.isReadOnlyArchive
                && herdrServer(for: bot) == server && server.id == receipt.server && bot.messages.contains { $0 === row }
                && row.deliveryReceipt == receipt && row.turnState == .incomplete && !row.isStreaming
        }
        guard current() else { return false }
        do {
            let outcome = try await receipt.read(from: herdrClient(for: server))
            guard current() else { return false }
            switch outcome {
            case .waiting: return true
            case .unresolved: break
            case .answered(let reply, let results):
                restoreSavedAnswer(reply, results: results, for: row, in: bot, serverID: server.id)
            }
            row.deliveryReceipt = nil
            bot.objectWillChange.send()
            objectWillChange.send()
            save()
            return false
        } catch {
            return !Task.isCancelled
        }
    }

    private func restoreSavedAnswer(_ reply: HerdrClient.Item, results: [HerdrPublishedResult], for row: ChatMessage,
                                    in bot: Bot, serverID: String) {
        guard let index = bot.messages.firstIndex(where: { $0 === row }) else { return }
        let origin = row.metadata[TurnReplyText.origin] ?? row.id.uuidString
        // Older receipts can predate explicit steer ownership. Only cross adjacent guidance
        // and status rows; an independent question or another reply starts a new turn.
        let following = bot.messages.suffix(from: index + 1).prefix {
            $0.role == .system || ($0.role == .user && $0.metadata[SteerKey.steer] != nil
                && ($0.metadata[TurnReplyText.origin] ?? origin) == origin)
        }
        let ended = reply.atMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now()
        let answer: ChatMessage
        if let anchor = following.last(where: { $0.metadata[SteerKey.steer] == "delivered" }),
           let anchorIndex = bot.messages.firstIndex(where: { $0 === anchor }) {
            answer = replyPartAfterGuidance(row, origin: origin, at: max(ended, anchor.createdAt))
            if answer === row { bot.messages.remove(at: index) }
            bot.messages.insert(answer, at: anchorIndex + (answer === row ? 0 : 1))
        } else { answer = row }

        let earlier = bot.messages.prefix { $0 !== answer }.filter {
            $0.role == .assistant && $0.metadata[TurnReplyText.origin] == origin
        }
        let prefix = TurnReplyText.joined(earlier)
        // Codex can save just its final answer, omitting earlier tool commentary. Other
        // providers can save a cumulative snapshot. Keep each earlier part exactly once.
        if !prefix.isEmpty, reply.text.hasPrefix(prefix + "\n\n"), reply.text.count > prefix.count + 2 {
            answer.content = String(reply.text.dropFirst(prefix.count + 2))
            answer.metadata[TurnReplyText.separator] = "\n\n"
        } else if !prefix.isEmpty, !answer.content.isEmpty,
                  reply.text.hasPrefix(prefix + (answer.metadata[TurnReplyText.separator] ?? "") + answer.content) {
            answer.content = String(reply.text.dropFirst(prefix.count + (answer.metadata[TurnReplyText.separator]?.count ?? 0)))
        } else {
            answer.content = reply.text
            if !prefix.isEmpty { answer.metadata[TurnReplyText.separator] = "\n\n" }
        }
        answer.isStreaming = false
        answer.turnState = .finished
        answer.deliveryReceipt = nil
        (earlier.first ?? answer).metadata["herdrJournal"] = "\(serverID):\(reply.id)"
        for part in earlier + [answer] {
            for key in [TurnKey.why, TurnKey.agent, TurnKey.ambiguous, TurnKey.reconnecting, "status"] { part.metadata[key] = nil }
            if var activity = part.activity, activity.endedAt == nil {
                activity.finish(at: max(activity.steps.last?.startedAt ?? part.createdAt, ended))
                part.activity = activity
            }
        }
        let shown = Set(earlier.flatMap { $0.publishedResults?.items.map(\.id) ?? [] })
        let remaining = results.filter { !shown.contains($0.id) }
        if !remaining.isEmpty { answer.publishedResults = HerdrReplyResults(serverID: serverID, items: remaining) }
    }

}

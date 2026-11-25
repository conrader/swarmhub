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
            for row in bot.messages where row.turnState == .incomplete && row.metadata[TurnKey.part] == nil {
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
                row.content = reply.text
                row.turnState = .finished
                row.metadata["herdrJournal"] = "\(server.id):\(reply.id)"
                for key in [TurnKey.why, TurnKey.agent, TurnKey.ambiguous, TurnKey.reconnecting, "status"] { row.metadata[key] = nil }
                if var activity = row.activity {
                    let ended = reply.atMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now()
                    activity.finish(at: max(activity.steps.last?.startedAt ?? row.createdAt, ended))
                    row.activity = activity
                }
                if !results.isEmpty { row.publishedResults = HerdrReplyResults(serverID: server.id, items: results) }
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
}

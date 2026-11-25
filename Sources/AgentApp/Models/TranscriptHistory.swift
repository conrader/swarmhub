import Foundation

enum TranscriptHistory {
    /// The saved position of new imports (and legacy imports after their one-time merge) is authoritative.
    private static let placed = "herdrHistoryPlaced"

    static func placement(_ row: ChatMessage) -> Date? {
        guard let value = row.metadata[placed], let seconds = Double(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Earlier builds appended workspace imports. Their timestamps identify where to merge
    /// them. Local rows keep their saved sequence, including any ambiguous old steer.
    static func restoring(_ rows: [ChatMessage]) -> [ChatMessage] {
        // A quit during the interrupt leaves its outcome unknown. Older saves recorded a failed interrupt
        // only in the system note immediately after the stopped reply.
        for (index, reply) in rows.enumerated() where reply.role == .assistant && reply.turnState == .stopped {
            let next = index + 1
            if reply.metadata[TurnKey.why] == TurnKey.stopPending ||
                (next < rows.count && rows[next].role == .system && IntentLine.stopFailed.matches(rows[next].content)) {
                reply.metadata[TurnKey.why] = TurnKey.stopUnconfirmed
            }
        }
        func needsPlacement(_ row: ChatMessage) -> Bool {
            row.metadata["herdrTeamEntry"] != nil && row.metadata[placed] == nil
        }
        let history = rows.enumerated().filter { needsPlacement($0.element) }
        guard !history.isEmpty else { return rows }
        let local = rows.enumerated().filter { !needsPlacement($0.element) }
        func precedes(_ lhs: (offset: Int, element: ChatMessage), _ rhs: (offset: Int, element: ChatMessage)) -> Bool {
            (lhs.element.transcriptDate, lhs.offset) < (rhs.element.transcriptDate, rhs.offset)
        }
        for (_, row) in history { row.metadata[placed] = "legacy" }
        return merging(history.sorted(by: precedes), into: local, by: precedes).map(\.element)
    }

    /// A held history page can fill a gap before a later entry from the same server.
    /// Direct follow-ups can be backfilled by the bridge, so use its timestamps among
    /// imported rows and its journal sequence against locally streamed replies.
    static func insert(_ row: ChatMessage, into rows: inout [ChatMessage], server: String,
                       entry: Int, followup: Bool, journal: Int?, receivedAt: Date) {
        let prefix = server + ":"
        func sequence(_ key: Substring) -> Int? {
            key.hasPrefix(prefix) ? Int(key.dropFirst(prefix.count)) : nil
        }
        var date = receivedAt, index = rows.endIndex, afterEarlierEntry = rows.startIndex
        for (i, saved) in rows.enumerated() {
            if let key = saved.metadata["herdrTeamEntry"], let id = sequence(key[...]) {
                if followup ? saved.createdAt > row.createdAt : id > entry {
                    index = i
                    // A delayed page can contain genuine older history. Measure its age
                    // against a known server entry, whose placement is on the Mac clock.
                    if let anchor = placement(saved) {
                        date = anchor.addingTimeInterval(min(0, row.createdAt.timeIntervalSince(saved.createdAt)))
                        index = rows[afterEarlierEntry..<i].firstIndex {
                            $0.transcriptDate > date
                        } ?? i
                    }
                    break
                }
                afterEarlierEntry = i + 1
            } else if followup, let journal, let ids = saved.metadata["herdrJournal"],
                      let first = ids.split(separator: " ").compactMap(sequence).min() {
                if first > journal {
                    // Keep the next locally authored question with its reply.
                    let trigger = saved.metadata[TurnKey.forUser]
                    index = rows[afterEarlierEntry..<i].firstIndex {
                        $0.role == .user && $0.id.uuidString == trigger
                    } ?? i
                    date = min(date, rows[index].transcriptDate)
                    break
                }
                afterEarlierEntry = i + 1
            }
        }
        row.metadata[placed] = String(date.timeIntervalSince1970)
        rows.insert(row, at: index)
    }

    /// A local turn can be placed under its queued trigger, or continue after a steer.
    /// Preserve both input sequences even when their creation times run backwards.
    static func merging<Row>(_ incoming: [Row], into local: [Row], by precedes: (Row, Row) -> Bool) -> [Row] {
        var merged: [Row] = []
        var remaining = incoming[...]
        for row in local {
            while let first = remaining.first, precedes(first, row) {
                merged.append(remaining.removeFirst())
            }
            merged.append(row)
        }
        merged.append(contentsOf: remaining)
        return merged
    }
}

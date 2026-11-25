import Foundation

enum TranscriptHistory {
    /// The saved position of new imports (and legacy imports after their one-time merge) is authoritative.
    private static let placed = "herdrHistoryPlaced"

    /// Earlier builds appended workspace imports. Their timestamps identify where to merge
    /// them. Local rows keep their saved sequence, including any ambiguous old steer.
    static func restoring(_ rows: [ChatMessage]) -> [ChatMessage] {
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
        func placement(_ row: ChatMessage) -> Date? {
            guard let value = row.metadata[placed], let seconds = Double(value) else { return nil }
            return Date(timeIntervalSince1970: seconds)
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
                            (placement($0) ?? $0.transcriptDate) > date
                        } ?? i
                    }
                    break
                }
                afterEarlierEntry = i + 1
            } else if followup, let journal, let ids = saved.metadata["herdrJournal"],
                      let first = ids.split(separator: " ").compactMap(sequence).min() {
                if first > journal { index = i; break }
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

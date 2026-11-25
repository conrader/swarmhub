import Foundation

enum TranscriptHistory {
    /// Earlier builds appended workspace imports. Their timestamps identify where to merge
    /// them. Local rows keep their saved sequence, including any ambiguous old steer.
    static func restoring(_ rows: [ChatMessage]) -> [ChatMessage] {
        let history = rows.enumerated().filter { $0.element.metadata["herdrTeamEntry"] != nil }
        guard !history.isEmpty else { return rows }
        let local = rows.enumerated().filter { $0.element.metadata["herdrTeamEntry"] == nil }
        func precedes(_ lhs: (offset: Int, element: ChatMessage), _ rhs: (offset: Int, element: ChatMessage)) -> Bool {
            (lhs.element.transcriptDate, lhs.offset) < (rhs.element.transcriptDate, rhs.offset)
        }
        return merging(history.sorted(by: precedes), into: local, by: precedes).map(\.element)
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

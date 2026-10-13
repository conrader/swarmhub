import Foundation

/// Cache + server history → one transcript (port of `_entry_from_body`, `merge_entries` and `coverage` in
/// `scripts/grokbot_server.py`). Pure: P10b's fetcher feeds it, P10a tests it.
enum GrokEntryMerge {
    /// A fetched row's JSON body as an entry: the row's `seq` always wins; the id is the body's string id, else the row's
    /// `entry_id`. Nil when the body is not a JSON object.
    static func entry(body: [UInt8], seq: Int64, entryID: String?) -> JSONValue? {
        guard var object = (try? GrokJSON.parse(Data(body)))?.objectValue else { return nil }
        object["seq"] = .int(seq)
        if object["id"]?.stringValue == nil, let entryID, !entryID.isEmpty { object["id"] = .string(entryID) }
        return .object(object)
    }

    /// Union by integer seq, sorted. On a collision the cached entry wins unless it is still streaming
    /// (`isStreaming == true`), in which case the server's settled copy replaces it.
    static func merge(cached: [JSONValue], fetched: [JSONValue]) -> [JSONValue] {
        var bySeq: [Int64: JSONValue] = [:]
        for entry in fetched { if let seq = entry["seq"]?.intValue { bySeq[seq] = entry } }
        for entry in cached {
            guard let seq = entry["seq"]?.intValue else { continue }
            if entry["isStreaming"]?.boolValue == true, bySeq[seq] != nil { continue }
            bySeq[seq] = entry
        }
        return bySeq.keys.sorted().map { bySeq[$0]! }
    }

    struct Coverage: Sendable, Equatable {
        var min: Int64?; var max: Int64?; var count: Int
        /// Closed ranges `[from, to]` of seqs in 1…max with no entry: information, never a warning.
        var gaps: [[Int64]]
        var complete: Bool
    }

    static func coverage(_ entries: [JSONValue]) -> Coverage {
        let seqs = Set(entries.compactMap { $0["seq"]?.intValue }).sorted()
        guard let first = seqs.first, let last = seqs.last else { return Coverage(min: nil, max: nil, count: 0, gaps: [], complete: false) }
        var gaps: [[Int64]] = [], expected: Int64 = 1
        for seq in seqs {
            if seq > expected { gaps.append([expected, seq - 1]) }
            expected = seq + 1
        }
        return Coverage(min: first, max: last, count: seqs.count, gaps: gaps, complete: gaps.isEmpty)
    }
}

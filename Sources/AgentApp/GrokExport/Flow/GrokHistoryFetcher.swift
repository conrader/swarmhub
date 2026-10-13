import Foundation

/// Pages one conversation's history backwards to seq 1 (port of `fetch_older` and `resolve_rows` in
/// `scripts/grokbot_server.py`, with the P10 paging rules): stop on an empty page or when the oldest seq is ≤ 1, never
/// on a short page; rows at or above the cursor are dropped, and a page that only had such rows means the server
/// ignored the cursor (`protocolChanged`). Bounded by `GrokProtocol.maxPagesPerBot`; checks cancellation between pages.
struct GrokHistoryFetcher: Sendable {
    struct Stats: Sendable, Equatable {
        var pages = 0, rows = 0, blobsRead = 0, blobsMissing = 0, omittedRefetched = 0, unreadable = 0
    }

    enum Stop: Sendable, Equatable {
        case pageCeiling
        case cancelled
        case failed(GrokServerError)
    }

    struct Result: Sendable {
        var entries: [JSONValue] = []
        var stats = Stats()
        /// Paging reached seq 1 or an empty page: nothing older exists on the server.
        var reachedStart = false
        /// Why paging ended early; nil when it reached the start.
        var stop: Stop?
        /// The `before_seq` of the next page to request (resume cursor); nil means the newest page.
        var nextBeforeSeq: Int64?
        /// The oldest seq fully fetched so far.
        var oldestFetched: Int64?
    }

    let client: GrokRPCClient
    var pageLimit = GrokProtocol.pageLimit
    var maxPages = GrokProtocol.maxPagesPerBot

    /// Fetches everything older than `beforeSeq` (exclusive; nil = from the newest). Never throws: a failure ends paging
    /// and is reported in `stop` with what was fetched so far, so a finished part can still be committed.
    /// `onPage` gets the page count and the oldest seq after each fully resolved page.
    func fetchOlder(agentID: String, beforeSeq: Int64?,
                    onPage: (@Sendable (_ pages: Int, _ oldestSeq: Int64) -> Void)? = nil) async -> Result {
        var result = Result(nextBeforeSeq: beforeSeq)
        var before = beforeSeq
        do {
            while true {
                if let before, before <= 1 { result.reachedStart = true; break }
                if Task.isCancelled { result.stop = .cancelled; break }
                if result.stats.pages >= maxPages { result.stop = .pageCeiling; break }
                let raw = try await client.listEntries(agentID: agentID, limit: pageLimit, beforeSeq: before)
                result.stats.pages += 1
                let rows = before.map { cursor in raw.filter { $0.seq < cursor } } ?? raw
                if rows.isEmpty {
                    guard raw.isEmpty else {
                        throw GrokServerError(.protocolChanged, kind: .list, errorType: "CursorIgnored")
                    }
                    result.reachedStart = true
                    break
                }
                var stats = result.stats
                let entries = try await resolve(agentID: agentID, rows: rows, stats: &stats)
                stats.rows += rows.count
                // Commit the page only once it is fully resolved, so a resume refetches a half-read page.
                result.stats = stats
                result.entries += entries
                let oldest = rows.map(\.seq).min()!
                result.oldestFetched = oldest
                result.nextBeforeSeq = oldest
                onPage?(result.stats.pages, oldest)
                if oldest <= 1 { result.reachedStart = true; break }
                before = oldest
            }
        } catch let error as GrokServerError {
            result.stop = .failed(error)
        } catch {
            result.stop = .cancelled
        }
        return result
    }

    /// Bodies for one page: inline, from presigned blobs, or by re-listing an omitted row on its own (limit 1).
    private func resolve(agentID: String, rows: [GrokProtobuf.TranscriptRow], stats: inout Stats,
                         refetchOmitted: Bool = true) async throws -> [JSONValue] {
        let hashes = Set(rows.compactMap { $0.body == nil ? $0.blobHash.flatMap { $0.isEmpty ? nil : $0 } : nil }).sorted()
        var blobs: [String: [UInt8]] = [:]
        if !hashes.isEmpty {
            try Task.checkCancellation()
            let urls = try await client.presign(relPaths: hashes.map { GrokProtocol.blobPathPrefix + $0 })
            for hash in hashes {
                try Task.checkCancellation()
                if let url = urls[GrokProtocol.blobPathPrefix + hash], let body = try await client.fetchBlob(url) {
                    blobs[hash] = body
                    stats.blobsRead += 1
                } else {
                    stats.blobsMissing += 1
                }
            }
        }
        var entries: [JSONValue] = []
        for row in rows {
            let body = row.body ?? row.blobHash.flatMap { blobs[$0] }
            if body == nil, row.bodyOmitted, refetchOmitted {
                try Task.checkCancellation()
                let again = try await client.listEntries(agentID: agentID, limit: 1, beforeSeq: row.seq + 1).filter { $0.seq == row.seq }
                stats.omittedRefetched += 1
                if var single = again.first {
                    // The single row comes back inline or as a blob; never re-list it a second time.
                    single.bodyOmitted = false
                    entries += try await resolve(agentID: agentID, rows: [single], stats: &stats, refetchOmitted: false)
                    continue
                }
            }
            if let body, let entry = GrokEntryMerge.entry(body: body, seq: row.seq, entryID: row.entryID) {
                entries.append(entry)
            } else {
                stats.unreadable += 1
            }
        }
        return entries
    }
}

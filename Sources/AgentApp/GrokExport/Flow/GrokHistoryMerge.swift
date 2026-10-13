import Foundation

/// The cache's entries plus one fetch → the conversation's transcript and its coverage (P10b 2). Merging is by seq
/// (`GrokEntryMerge.merge`: the cached entry wins unless it is still streaming).
enum GrokHistoryMerge {
    /// Three-valued, so an early stop is never shown as a server gap.
    enum Coverage: Sendable, Equatable {
        /// Paging reached the start and every seq from 1 to the newest is present.
        case complete
        /// Paging reached the start; Grok has no entry for these closed seq ranges (information, never a warning).
        case serverGaps([[Int64]])
        /// Paging stopped early: nothing older than `stoppedAt` was fetched. `gaps` lists only ranges above it.
        case incomplete(stoppedAt: Int64?, gaps: [[Int64]])
    }

    struct Result: Sendable {
        var entries: [JSONValue]
        var coverage: Coverage
        var summary: GrokEntryMerge.Coverage
    }

    static func merge(cached: [JSONValue], fetched: GrokHistoryFetcher.Result) -> Result {
        let entries = GrokEntryMerge.merge(cached: cached, fetched: fetched.entries)
        let summary = GrokEntryMerge.coverage(entries)
        let coverage: Coverage
        if fetched.reachedStart {
            coverage = summary.gaps.isEmpty ? .complete : .serverGaps(summary.gaps)
        } else {
            let stoppedAt = fetched.oldestFetched ?? summary.min
            coverage = .incomplete(stoppedAt: stoppedAt, gaps: summary.gaps.filter { gap in stoppedAt.map { gap[0] > $0 } ?? false })
        }
        return Result(entries: entries, coverage: coverage, summary: summary)
    }
}

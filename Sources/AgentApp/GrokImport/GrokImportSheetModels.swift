import Foundation

/// One conversation on the sheet's Found step: what Grok Bot's cache says about it, plus what this app already holds.
/// Built with no prompt and no network; carries names and counts only.
struct GrokFoundItem: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var isGroup: Bool
    var memberIDs: [String]
    var mark: AvatarMark
    /// The profile the bot chats through: an existing bot's own, else the one the builder chose; nil = history only.
    var profile: String?
    var cachedMessages: Int
    /// The newest seq in the cache: the request estimate and the progress bar's "about" denominator.
    var newestCachedSeq: Int64
    var hiddenInGrok: Bool
    /// Lines already in this app's archive for it, and when that archive was last written (nil = never imported).
    var importedLines = 0
    var importedAt: Date?

    /// List requests a full fetch needs at least: one page of 500 per started 500 seqs, one for an empty history.
    var minimumRequests: Int { max(1, Int((newestCachedSeq + Int64(GrokProtocol.pageLimit) - 1) / Int64(GrokProtocol.pageLimit))) }
}

/// One row of the Importing step.
struct GrokProgressRow: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case queued, readingCache, fetching, saving, done, incomplete, paused
        case skipped(String)
        case failed(String)
    }

    let id: String
    var name: String
    var isGroup: Bool
    var status: Status = .queued
    var pages = 0
    var oldestSeq: Int64?
    /// The cache's newest seq; the bar is (newest - oldest + 1) / newest, labelled "about".
    var newestSeq: Int64

    var rowsFetched: Int64 { oldestSeq.map { max(0, newestSeq - $0 + 1) } ?? 0 }
    var fraction: Double {
        switch status {
        case .done, .incomplete, .skipped: return 1
        default: return newestSeq > 0 ? min(1, Double(rowsFetched) / Double(newestSeq)) : 0
        }
    }

    var label: String {
        switch status {
        case .queued: "Queued"
        case .readingCache: "Reading the cache"
        case .fetching: pages == 0 ? "Fetching" : "Fetching: page \(pages), about \(rowsFetched) of \(newestSeq) entries" +
            (oldestSeq.map { ", at seq \($0)" } ?? "")
        case .saving: "Saving"
        case .done: "Done"
        case .incomplete: "Incomplete"
        case .paused: "Paused"
        case .skipped(let reason): "Skipped: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Whether an imported bot can chat, measured after the import (`GET /p/<profile>/v1/models` names the profile).
enum GrokConnection: Equatable, Sendable {
    case checking, live, needsKey, profileNotOnServer, unreachable, historyOnly

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .live: "Live"
        case .needsKey: "Needs key"
        case .profileNotOnServer: "Profile not on the server"
        case .unreachable: "Server unreachable"
        case .historyOnly: "History only"
        }
    }
}

/// One imported conversation on the Done step. Counts are read back from the store and the archive file.
struct GrokImportOutcome: Identifiable, Equatable, Sendable {
    let id: String
    var botID: UUID?
    var name: String
    var isGroup: Bool
    var profile: String?
    var archiveLines: Int
    var connection: GrokConnection
    var row: GrokImportRunRow

    var coverageText: String {
        switch row.coverage {
        case .complete where row.gapRanges == 0: return "Complete"
        case .complete, .serverGaps: return "Complete; Grok has no entry for \(row.missingSeqs) sequence numbers inside this history"
        case .incomplete:
            return "Incomplete: stopped" + (row.stats.pages > 0 ? " after \(row.stats.pages) pages" : "") + ", nothing older was fetched"
        case .cacheOnly: return "Recent messages from this Mac only"
        }
    }

    var droppedText: String? {
        guard !row.droppedByKind.isEmpty else { return nil }
        return row.droppedByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

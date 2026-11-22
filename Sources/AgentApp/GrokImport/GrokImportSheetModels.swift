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
    var description = ""
    var needsDescriptionEdit = false
    var memberNames: [String] = []

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

/// One imported conversation on the Done step. Counts are read back from the store and the archive file.
struct GrokImportOutcome: Identifiable, Equatable, Sendable {
    let id: String
    var botID: UUID?
    var name: String
    var isGroup: Bool
    var archiveLines: Int
    var row: GrokImportRunRow

    var coverageText: String {
        switch row.coverage {
        case .complete where row.gapRanges == 0: return "Complete"
        case .complete, .serverGaps: return "Complete; Grok has no entry for \(row.missingSeqs) sequence numbers inside this history"
        case .incomplete:
            if let reason = row.reason { return "Partial · " + reason }
            return "Incomplete: stopped" + (row.stoppedAtSeq.map { " at seq \($0)" } ?? "") + ", nothing older was fetched"
        case .fileExport: return "History from the selected export"
        case .cacheOnly: return "Recent messages from this Mac only"
        }
    }

    var statusLabel: String {
        switch row.status {
        case .done: "Imported"
        case .incomplete: "Partial"
        case .skipped: "Skipped"
        }
    }

    var droppedText: String? {
        guard !row.droppedByKind.isEmpty else { return nil }
        return row.droppedByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

/// The last time Grok's service stopped All history, kept in the app's defaults so the sheet opens on Recent messages
/// instead of asking macOS for a sign-in Grok will refuse again. A date, plain words and the account it was about. It is
/// forgotten when All history works, after a week, and when another account is signed in to Grok Bot: an account that
/// was put right is then asked again without the user having to know the note exists.
struct GrokRefusalNote: Codable, Equatable, Sendable {
    var date: Date
    var summary: String
    /// Grok Bot's id of the signed-in account (`cursor-accounts.active`); nil when it could not be read.
    var account: String?

    static let key = "grokImportLastRefusal"
    static let lifetime: TimeInterval = 7 * 24 * 3600

    static func load(_ defaults: UserDefaults, now: Date, account: String?) -> GrokRefusalNote? {
        guard let note = defaults.data(forKey: key).flatMap({ try? JSONDecoder().decode(GrokRefusalNote.self, from: $0) }) else { return nil }
        let otherAccount = note.account != nil && account != nil && note.account != account
        if now.timeIntervalSince(note.date) > lifetime || otherAccount {
            clear(defaults)
            return nil
        }
        return note
    }

    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func clear(_ defaults: UserDefaults) { defaults.removeObject(forKey: key) }
}

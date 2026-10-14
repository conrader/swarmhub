import Foundation

/// Why a run stopped or could not start. Every case is secret-free: no URL, header, body, token or message text.
enum GrokImportRunError: Error, Sendable, Equatable, LocalizedError {
    case alreadyRunning
    /// Another Keychain read is still pending (app-wide); Continue waits until the stale call returns.
    case keychainReadInFlight
    case persistenceDisabled
    case cache(GrokCacheError)
    case unknownBots(Int)
    case serverHistoryOff
    case signedOut
    case keychainItemMissing
    /// Deny, a locked keychain, or another Keychain failure: nothing was read; Recent messages still works.
    case keychain(GrokKeychainError)
    case credentials(GrokCredentialsError)
    /// The Keychain bytes did not unlock the sign-in (a wrong key, or a format this app does not know).
    case signInUnreadable
    /// Grok's service refused the run or answered in a format this app does not know: nothing more is written.
    case server(GrokServerError)
    /// The store could not be saved: the run stops, bots committed so far stay.
    case local(GrokImportError)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "An import from Grok Bot is already running."
        case .keychainReadInFlight: "macOS is still waiting for an answer to the earlier Keychain request. Answer or close it first."
        case .persistenceDisabled: GrokImportError.persistenceDisabled.errorDescription
        case .cache(let error): error.errorDescription
        case .unknownBots(let count): "\(count) of the named bots are not in Grok Bot's bot list."
        case .serverHistoryOff: "This build imports only the recent messages kept on this Mac."
        case .signedOut: "Grok Bot is not signed in on this Mac. Open Grok Bot once and sign in, or import Recent messages."
        case .keychainItemMissing: "Grok Bot's sign-in is not in the Keychain. Sign in to Grok Bot first, or import Recent messages."
        case .keychain(.denied): "macOS did not allow the Keychain read, so nothing was read. Recent messages can still be imported."
        case .keychain(.keychainLocked): "The login keychain is locked. Unlock it and try again."
        case .keychain(let error): "The Keychain read failed (\(error.description)). Recent messages can still be imported."
        case .credentials(let error): "Grok Bot's sign-in could not be used: \(error.description)."
        case .signInUnreadable: "Grok Bot's sign-in could not be unlocked on this Mac."
        case .server(let error): error.errorDescription
        case .local(let error): error.errorDescription
        }
    }

    /// The Recent-messages import (cache only, no prompt, no network) is still possible.
    var recentStillAvailable: Bool {
        switch self {
        case .keychain, .credentials, .signInUnreadable, .server, .serverHistoryOff, .signedOut, .keychainItemMissing: true
        default: false
        }
    }
}

/// Why a run paused (resumable without losing the bots already imported).
enum GrokImportPause: Sendable, Equatable {
    /// A network error or 502/503/504 after the retries: Retry remaining continues from the cursor, no second prompt.
    case network(GrokServerError)
    /// The sign-in had expired: the key is held (at most `GrokProtocol.signInHold`); open Grok Bot once, then Check again.
    case tokenExpired
    /// HTTP 401 mid-run: nothing is held; Continue makes macOS ask again.
    case signInInvalid
}

enum GrokImportRunState: Sendable, Equatable {
    case idle
    case preflighting
    /// The one Keychain read is pending: macOS may be showing its dialog.
    case awaitingMacOS
    case running
    case paused(GrokImportPause)
    case finished
    case stopped(GrokImportRunError)
    /// Cancelled; `importWhatWasFetched()` commits the interrupted conversation as incomplete.
    case cancelled

    var isActive: Bool { self == .preflighting || self == .awaitingMacOS || self == .running }
    var isPaused: Bool { if case .paused = self { true } else { false } }
}

enum GrokImportMode: String, Sendable, CaseIterable {
    /// The latest 28–200 entries per chat from Grok Bot's cache: no prompt, no network.
    case recent
    /// Everything Grok returns: one Keychain Allow, read-only requests to `api2.cursor.sh`.
    case full
}

struct GrokImportOptions: Sendable, Equatable {
    var mode: GrokImportMode = .full
    /// Roster ids or names (case-insensitive) to import; nil imports every conversation. A group brings its members.
    var selection: [String]?
    var refreshIdentity = false
}

/// One conversation's result, read back from what was committed. Counts only, plus the bot's display name.
struct GrokImportRunRow: Sendable, Equatable {
    enum Status: String, Sendable { case done, incomplete, skipped }
    enum Coverage: String, Sendable { case complete, serverGaps = "server-gaps", incomplete, cacheOnly = "cache-only" }

    var sourceID: String
    var name: String
    var isGroup: Bool
    var status: Status
    var coverage: Coverage
    /// A secret-free reason when skipped.
    var reason: String?
    var cachedEntries = 0
    var fetchedEntries = 0
    var messages = 0
    /// Lines in the bot's archive after the commit, and how many of them this run added.
    var archiveLines = 0
    var addedLines = 0
    var gapRanges = 0
    var missingSeqs: Int64 = 0
    var stats = GrokHistoryFetcher.Stats()
    /// Entries not imported, by kind (and card type), as the mapper counted them.
    var droppedByKind: [String: Int] = [:]
    /// Secret-like text replaced by `[REDACTED]`, and hidden prompts kept and marked.
    var redactions = 0
    var hiddenMessages = 0
}

/// The injected world of a run: Grok Bot's location, the password provider, the transport and clocks.
struct GrokImportEnvironment: Sendable {
    var location: GrokLocation
    var passwords: any GrokPasswordProvider
    var gate: GrokKeychainGate
    var makeSession: @Sendable () -> GrokSession
    var baseURL: URL = GrokProtocol.baseURL
    var clock: any GrokClock
    var now: @Sendable () -> Date = { Date() }
    var appVersion: String
    var hold: Duration = GrokProtocol.signInHold

    static func live(appVersion: String) -> GrokImportEnvironment {
        GrokImportEnvironment(location: .live(), passwords: GrokKeychain(), gate: .shared, makeSession: { GrokSession.live() },
                              clock: GrokSystemClock(), appVersion: GrokRequestHeaders.appVersion(fromShortVersion: appVersion))
    }
}

/// What has been fetched for the conversation a pause or cancel interrupted; resumed from `nextBeforeSeq`.
struct GrokFetchProgress: Sendable {
    let sourceID: String
    var result = GrokHistoryFetcher.Result()

    init(sourceID: String) { self.sourceID = sourceID }

    mutating func absorb(_ next: GrokHistoryFetcher.Result) {
        result.entries += next.entries
        result.stats.pages += next.stats.pages
        result.stats.rows += next.stats.rows
        result.stats.blobsRead += next.stats.blobsRead
        result.stats.blobsMissing += next.stats.blobsMissing
        result.stats.omittedRefetched += next.stats.omittedRefetched
        result.stats.unreadable += next.stats.unreadable
        result.reachedStart = next.reachedStart
        result.stop = next.stop
        result.nextBeforeSeq = next.nextBeforeSeq
        if let oldest = next.oldestFetched { result.oldestFetched = oldest }
    }
}

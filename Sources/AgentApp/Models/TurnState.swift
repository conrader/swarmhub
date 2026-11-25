import Foundation

/// What the Mac knows about a reply row. nil = written by a build that kept no state.
/// `finished`: the agent closed the turn (a terminal event arrived). `incomplete`: the row exists and the turn has not
/// been shown to end (a row is born this way). `stopped`: the user pressed Stop. `notSent`: the turn did not reach the
/// server as far as the Mac knows; the row is kept, empty.
enum TurnState: String, Codable, Sendable { case finished, incomplete, stopped, notSent }

/// A stream that ended without a terminal event. `delivered`: the response headers had arrived, so the server has the
/// turn. `requestStarted == false`: `URLSessionTaskMetrics` show the request never left the Mac.
struct StreamBreak: LocalizedError {
    let delivered: Bool; let underlying: Error; var requestStarted: Bool? = nil
    /// The underlying error of a clean end of file without a terminal event.
    struct EndOfStream: LocalizedError { var errorDescription: String? { "The connection closed before the bot finished its reply." } }
    var errorDescription: String? { underlying.localizedDescription }
    var isEndOfStream: Bool { underlying is EndOfStream }
}

/// How a turn ended, as the one stream consumer saw it.
enum TurnEnd {
    case completed, stoppedByUser, failedByAgent(String), endedWithoutTerminal, error(Error)
}

/// Pure classification of a turn's end: the row state, its reason, the footer, whether the server may have it, and
/// what happens to the rest of a group round.
struct TurnOutcome: Equatable {
    enum Round: Equatable { case continues, stopsRest(why: String) }
    var state: TurnState
    var why: String? = nil
    var ambiguous = false
    var round: Round = .continues
    /// The reason for the persisted warning line; nil = no line (finished, stopped).
    var reason: String? = nil

    static let certainlyUnsentCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed]
    static let ambiguousCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost]
    static let refusedStatuses: Set<Int> = [401, 403, 409, 422, 429]

    static func classify(_ end: TurnEnd) -> TurnOutcome {
        switch end {
        case .completed: return .init(state: .finished)
        case .stoppedByUser: return .init(state: .stopped, why: "stopped")
        case .failedByAgent(let text): return .init(state: .incomplete, why: "error", reason: text)
        case .endedWithoutTerminal: return .init(state: .incomplete, reason: StreamBreak.EndOfStream().localizedDescription)
        case .error(let error): return classify(error: error)
        }
    }

    static func classify(error: Error) -> TurnOutcome {
        let reason = error.localizedDescription
        let streamBreak = error as? StreamBreak
        if let failure = (streamBreak?.underlying ?? error) as? HerdrClient.Failure,
           failure == .unconfirmedDelivery || failure == .startNotObserved {
            return .init(state: .notSent, why: "error", ambiguous: true, reason: reason)
        }
        if let streamBreak {
            if streamBreak.delivered {
                if streamBreak.isEndOfStream { return .init(state: .incomplete, reason: reason) }
                return .init(state: .incomplete, why: "offline", round: .stopsRest(why: "offline"), reason: reason)
            }
            if streamBreak.requestStarted == false { return .init(state: .notSent, why: "offline", round: .stopsRest(why: "offline"), reason: reason) }
            return classify(error: streamBreak.underlying)
        }
        if let urlError = error as? URLError {
            if certainlyUnsentCodes.contains(urlError.code) { return .init(state: .notSent, why: "offline", round: .stopsRest(why: "offline"), reason: reason) }
            if ambiguousCodes.contains(urlError.code) {
                let why = urlError.code == .timedOut ? "timeout" : "offline"
                return .init(state: .notSent, why: why, ambiguous: true, round: .stopsRest(why: why), reason: reason)
            }
            return .init(state: .notSent, why: "error", reason: reason)
        }
        if case BackendError.http(let code, _) = error {
            if refusedStatuses.contains(code) { return .init(state: .notSent, why: "refused", reason: reason) }
            if (500..<600).contains(code) { return .init(state: .notSent, why: "error", ambiguous: true, round: .stopsRest(why: "timeout"), reason: reason) }
        }
        return .init(state: .notSent, why: "error", reason: reason)
    }

    /// The footer under the reply row (nil = none).
    static func footer(state: TurnState?, why: String?, ambiguous: Bool, empty: Bool) -> String? {
        switch state {
        case .notSent?:
            let reason = why.map { " (\($0))" } ?? ""
            return ambiguous ? "Not confirmed\(reason) — the bot may have it" : "Not sent\(reason)"
        case .incomplete?: return "Incomplete"
        case .stopped?:
            if why == TurnKey.stopPending { return "Waiting for stop confirmation…" }
            if why == TurnKey.stopUnconfirmed { return "Stop unconfirmed. The bot may still be running." }
            return empty ? "Stopped" : nil
        case .finished?: return empty && why == "later" ? "Delivered with a later message" : nil
        case nil: return nil
        }
    }
}

extension ChatMessage {
    var stopUnconfirmed: Bool { turnState == .stopped && metadata[TurnKey.why] == TurnKey.stopUnconfirmed }
}

/// Metadata keys and stop-confirmation values on reply rows.
enum TurnKey {
    static let stopPending = "stop-pending"
    static let stopUnconfirmed = "stop-unconfirmed"
    static let forUser = "for", why = "why", ambiguous = "ambiguous", tone = "tone"
    /// A second tap is needed before a reply the agent may already have is sent again.
    static let end = "end", retry = "retry"
    /// A reply split by a delivered steer: "1" on the part before it, "2", "3"… on the parts after.
    static let part = "part"
    /// The connection dropped and the turn is resending; the live line says "Reconnecting…".
    static let reconnecting = "reconnecting"
    /// What the turn is waiting for, as the agent's server reports it (`HerdrTurnStatus.code`); only while it runs.
    static let agent = "agent"
}

/// An app-only line about a message the restart left in doubt. It is shown in the chat and never sent as history.
enum ReconcileNote {
    static let key = "reconcileNote"
    static let uncertainQueuePrefix = "Queued message delivery is uncertain after restart. Check the chat before sending again: "

    static func line(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text, metadata: [key: "1"]) }

    /// Tagged rows, and untagged ones saved before the tag existed.
    static func isNote(_ row: ChatMessage) -> Bool {
        row.metadata[key] != nil || (row.role == .system && row.content.hasPrefix(uncertainQueuePrefix))
    }
}

/// The row's status while a turn that never left the Mac waits to be sent again.
enum TurnErrorCopy { static let reconnecting = "Reconnecting…" }

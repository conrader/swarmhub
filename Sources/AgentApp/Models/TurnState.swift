import Foundation

/// P16: what the Mac knows about a reply row. nil = written before P16 (the reconcile treats it as possibly truncated).
/// `finished`: the box closed the run (a terminal event arrived). `incomplete`: the row exists and the turn has not been
/// shown to end (a row is born this way). `stopped`: the user pressed Stop. `notSent`: the turn did not reach the box as
/// far as the Mac knows; the row is kept, empty.
enum TurnState: String, Codable, Sendable { case finished, incomplete, stopped, notSent }

/// A stream that ended without a terminal event. `delivered`: the response headers had arrived, so the box has the turn.
/// `requestStarted == false`: `URLSessionTaskMetrics` show the request never left the Mac.
struct StreamBreak: LocalizedError {
    let delivered: Bool; let underlying: Error; var requestStarted: Bool? = nil
    /// The underlying error of a clean end of file without a terminal event.
    struct EndOfStream: LocalizedError { var errorDescription: String? { "The connection closed before the box finished the reply." } }
    var errorDescription: String? { underlying.localizedDescription }
    var isEndOfStream: Bool { underlying is EndOfStream }
}

/// How a turn ended, as the one stream consumer saw it.
enum TurnEnd {
    case completed, stoppedByUser, failedByBox(String), endedWithoutTerminal, error(Error)
}

/// Pure classification of a turn's end (P16 table): the row state, its reason, the footer, whether the box may have it,
/// whether to reconcile, and what happens to the rest of a group round.
struct TurnOutcome: Equatable {
    enum Round: Equatable { case continues, stopsRest(why: String) }
    var state: TurnState
    var why: String? = nil
    var ambiguous = false
    var reconcile = false
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
        case .failedByBox(let text): return .init(state: .incomplete, why: "error", reconcile: true, reason: text)
        case .endedWithoutTerminal: return .init(state: .incomplete, reconcile: true, reason: StreamBreak.EndOfStream().localizedDescription)
        case .error(let error): return classify(error: error)
        }
    }

    static func classify(error: Error) -> TurnOutcome {
        let reason = error.localizedDescription
        if let streamBreak = error as? StreamBreak {
            if streamBreak.delivered {
                if streamBreak.isEndOfStream { return .init(state: .incomplete, reconcile: true, reason: reason) }
                return .init(state: .incomplete, why: "offline", reconcile: true, round: .stopsRest(why: "offline"), reason: reason)
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
        if error is ModelRefusal { return .init(state: .notSent, why: "refused", reason: reason) }
        return .init(state: .notSent, why: "error", reason: reason)
    }

    /// The footer under the reply row (nil = none).
    static func footer(state: TurnState?, why: String?, ambiguous: Bool, empty: Bool) -> String? {
        switch state {
        case .notSent?:
            let reason = why.map { " (\($0))" } ?? ""
            return ambiguous ? "Not confirmed\(reason) — the box may have it" : "Not sent\(reason)"
        case .incomplete?: return "Incomplete"
        case .stopped?: return empty ? "Stopped" : nil
        case .finished?: return empty && why == "later" ? "Delivered with a later message" : nil
        case nil: return nil
        }
    }
}

/// Metadata keys P16 writes on rows.
enum TurnKey {
    static let forUser = "for", run = "run", why = "why", ambiguous = "ambiguous", restored = "restored", box = "box", tone = "tone"
    /// How the box ended a reply it holds no more of ("none" or "error"), the result of the user's Refresh, and Retry prompts.
    static let end = "end", check = "check", retry = "retry"
    /// P28 D5: a reply split by a delivered steer: "1" on the part before it, "2", "3"… on the parts after.
    static let part = "part"
    /// P38 E: estimated tokens of the hidden tool and workflow-operation turns inside a reply (`ConnectedAppsChat`).
    static let toolTokens = "toolTokens"
    /// uxfix1: the connection dropped and the turn is reconnecting (or resending); the live line says "Reconnecting…".
    static let reconnecting = "reconnecting"
}

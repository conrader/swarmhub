import Foundation

/// P48: a bot's app request that failed at Composio or on the way there. The bot gets it back as a "SwarmHub app result"
/// and the chat shows the same line; the turn goes on. Refusals of SwarmHub's own rules (access changed, an undiscovered
/// tool) still end the turn. P52: also an unreadable answer (`ComposioError.unreadable`), a request the bot wrote that
/// SwarmHub could not read (`AppRequestError`) and any lost connection; each is logged once (`log`).
struct AppRequestFailure: Error {
    let error: Error
    /// The app and action ("GitHub · Run graph ql query") when an execution failed.
    var tool: String?
    /// False when Composio answered with an error, so the action did not run; true when its outcome is unknown.
    var ran = false
    var text = ""

    /// Composio refused the request (a 4xx), so it did not run. A 5xx or a lost connection may have run: outcome unknown.
    static func answered(_ error: Error) -> Bool {
        switch error as? ComposioError {
        case .api(let failure): (400..<500).contains(failure.status)
        case .http(let status): (400..<500).contains(status)
        default: false
        }
    }

    static func returnsToBot(_ error: Error) -> Bool {
        if error is AppRequestFailure || error is AppAccountChoiceError || error is AppRequestError || error is DecodingError || error is EncodingError { return true }
        if let error = error as? URLError { return error.code != .cancelled }
        switch error as? ComposioError {
        case .api, .http, .invalidResponse, .tooLarge, .unreadable: return true
        default: return false
        }
    }

    /// P52: the developer log's line for a failure the bot gets back: what was asked and what failed. Composio's own
    /// errors carry its capped, redacted message or the answer's shape; an account choice is named only by kind (its
    /// text lists account names).
    func logLine(action: String) -> String {
        let what = (error as? AppAccountChoiceError).map { _ in "the account the bot named is not one it may use" } ?? text
        return "App request failed (\(action)\(tool.map { " · " + $0 } ?? "")\(ran ? ", outcome unknown" : "")): \(what)"
    }

    static func wrap(_ error: Error, describe: (Error) -> String) -> Self {
        var failure = (error as? Self) ?? Self(error: error)
        failure.text = describe(failure.error)
        return failure
    }

    var chatLine: String {
        guard let tool else { return "App request failed: \(text)" }
        return ran ? "\(tool) may not have finished: \(text)" : "\(tool) failed: \(text)"
    }

    /// The bot's result: the error, and for an unknown outcome a warning not to repeat the action blindly.
    var botResult: String {
        var fields: [String: ComposioValue] = ["error": .string(text)]
        if let tool { fields["tool"] = .string(tool) }
        if ran { fields["note"] = .string("The outcome is unknown. Do not repeat this action without asking the user.") }
        return (try? ComposioValue.object(fields).text()) ?? "{\"error\":\"App request failed.\"}"
    }
}


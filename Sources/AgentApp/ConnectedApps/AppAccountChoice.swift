import Foundation

/// P48: the account a bot's execute uses. The bot names it (`"account":"<name>"`) by the names SwarmHub listed; only
/// accounts granted to this bot are accepted. With one account the name may be left out; with several it is required and
/// nothing is guessed. The id never comes from the bot unchecked.
enum AppAccountChoice {
    static func resolve(_ name: String?, toolkit: String, appName: String, scope: ComposioRunScope) throws -> String {
        let ids = scope.accounts[toolkit] ?? []
        let names = ids.map { scope.labels[$0] ?? $0 }
        let listed = names.map { "\"\($0)\"" }.joined(separator: ", ")
        guard let wanted = name?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else {
            if ids.count == 1 { return ids[0] }
            throw AppAccountChoiceError(message: "This bot has \(ids.count) \(appName) accounts. Repeat the request with \"account\" set to one of: \(listed).")
        }
        if ids.contains(wanted) { return wanted }
        // A name must point at exactly one account; an exact match wins over one that differs only in case.
        let exact = ids.filter { scope.labels[$0] == wanted }
        let loose = ids.filter { (scope.labels[$0] ?? "").compare(wanted, options: .caseInsensitive) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        if exact.isEmpty, loose.count == 1 { return loose[0] }
        if exact.count + loose.count > 1 {
            throw AppAccountChoiceError(message: "\"\(wanted)\" names more than one \(appName) account. Use the account's id instead: \(exact.isEmpty ? loose.joined(separator: ", ") : exact.joined(separator: ", ")).")
        }
        throw AppAccountChoiceError(message: "\"\(wanted)\" is not one of this bot's \(appName) accounts. Use one of: \(listed).")
    }

    /// The accounts the bot sees beside discovered tools: app → names.
    static func names(for toolkits: Set<String>, scope: ComposioRunScope) -> ComposioValue {
        .object(Dictionary(uniqueKeysWithValues: toolkits.sorted().map { app in (app, ComposioValue.strings((scope.accounts[app] ?? []).map { scope.labels[$0] ?? $0 })) }))
    }
}

/// P48: the account a bot named could not be used; it goes back to the bot as an app result.
struct AppAccountChoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

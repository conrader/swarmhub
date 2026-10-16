import Foundation

/// P48: which bots use each connected account, for the Connect apps sheet. The switches there are Agent access's
/// `setAllowed`, so the same 10-per-app cap holds.
extension ConnectedAppsStore {
    /// The bots of `bots` this account is switched on for, in their order.
    func bots(using account: ComposioAccount, among bots: [Bot]) -> [Bot] { bots.filter { allows(account, botID: $0.id) } }

    /// Whether this bot's switch for the account can be turned on: the account works and the bot has fewer than
    /// `accountsPerApp` other accounts of that app on.
    func canAllow(_ account: ComposioAccount, botID: UUID) -> Bool {
        account.isActive && grantedCount(of: account.toolkit, in: grants(for: botID).filter { $0 != account.id }) < Self.accountsPerApp
    }
}

extension ConnectedAppsCopy {
    static let notUsedByAnyBot = "Not used by any bot"
    static func usedBy(_ names: [String]) -> String { names.isEmpty ? notUsedByAnyBot : "Used by " + names.joined(separator: ", ") }
    static let accountsPerAppCap = "A bot can use at most \(ConnectedAppsStore.accountsPerApp) accounts of one app."
}

import Foundation

/// P48: the read-only profile call that tells who a connected account is. One line per app; an app not listed keeps
/// its fallback name ("Gmail account 2 · 16 Oct 2026"). Only the name field is read from the result, never tokens.
enum AccountProfileName {
    static let table: [String: (tool: String, field: String)] = [
        "gmail": ("GMAIL_GET_PROFILE", "emailAddress"),
        "github": ("GITHUB_GET_THE_AUTHENTICATED_USER", "login"),
    ]

    /// The name field from an execute result (`data`, `data.response_data` or the top level), one plain line.
    static func read(_ result: ComposioValue, field: String) -> String? {
        guard result["successful"].bool != false else { return nil }
        for place in [result["data"], result["data"]["response_data"], result] {
            if let raw = place[field].string {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, name.count <= 100, !name.contains(where: \.isNewline) { return name }
            }
        }
        return nil
    }
}

extension ConnectedAppsStore {
    static let aliasLimit = 100

    /// P48: names every active account that has no alias and an entry in the table, once per launch: the profile call
    /// in a single-account session pinned to that account (SwarmHub's own read, not a bot action, so no approval), then
    /// the alias at Composio so the name survives reinstalls.
    func nameUnnamedAccounts(using service: ComposioClient) async {
        for account in accounts where account.isActive && !account.hasName && AccountProfileName.table[account.toolkit] != nil {
            guard namingAttempted.insert(account.id).inserted else { continue }
            namingAccounts.insert(account.id); defer { namingAccounts.remove(account.id) }
            do {
                let alias = try await saveAlias(try await profileName(of: account, using: service), for: account, using: service)
                if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = accounts[index].withAlias(alias) }
            } catch { ComposioClient.log.error("Naming a \(account.toolkit, privacy: .public) account failed: \(self.describe(error), privacy: .public)") }
        }
    }

    func profileName(of account: ComposioAccount, using service: ComposioClient) async throws -> String {
        guard let entry = AccountProfileName.table[account.toolkit] else { throw ComposioError.invalidIdentifier }
        let session = try await service.createSession(userID: configuration.userID, toolkits: [account.toolkit], accounts: [account.toolkit: [account.id]])
        defer { Task { await service.deleteSession(session) } }
        let result = try await service.execute(sessionID: session, tool: entry.tool, arguments: .object([:]))
        guard let name = AccountProfileName.read(result, field: entry.field) else { throw ComposioError.invalidResponse }
        return name
    }

    /// Sets `base` as the alias; a duplicate (409) becomes "base (2)", "base (3)"… Returns the alias saved.
    func saveAlias(_ base: String, for account: ComposioAccount, using service: ComposioClient) async throws -> String {
        let base = String(base.prefix(Self.aliasLimit))
        for n in 1...9 {
            let alias = n == 1 ? base : "\(base) (\(n))"
            do { try await service.setAlias(alias, account: account.id); return alias }
            catch ComposioError.api(let failure) where failure.status == 409 { continue }
            catch ComposioError.http(409) { continue }
        }
        throw ComposioError.http(409)
    }
}

import Foundation

/// P48/P53: who a connected account is: one read-only identity call per account, and the name found in its result
/// (email, username, "user @ workspace"). An account without a name keeps its fallback ("Gmail account 2 · 16 Oct 2026").
/// Only a name is ever taken from the result, never a token.
enum AccountProfileName {
    struct Call: Sendable, Equatable {
        let tool: String
        var arguments: ComposioValue = .object([:])
    }

    /// The name found and the key path it was found under (`data.emailAddress`).
    struct Found: Sendable, Equatable { let name: String; let path: String }

    /// Known identity tools (Composio v3.1 docs, 2026-10-16), tried in order. One line per app.
    static let known: [String: [Call]] = [
        "gmail": [.init(tool: "GMAIL_GET_PROFILE")],
        "github": [.init(tool: "GITHUB_GET_THE_AUTHENTICATED_USER")],
        "googlecalendar": [.init(tool: "GOOGLECALENDAR_GET_CURRENT_USER"), .init(tool: "GOOGLECALENDAR_CALENDAR_LIST_GET", arguments: .object(["calendarId": .string("primary")]))],
        "googledrive": [.init(tool: "GOOGLEDRIVE_GET_ABOUT", arguments: .object(["fields": .string("user")]))],
        "slack": [.init(tool: "SLACK_TEST_AUTH")],
        "notion": [.init(tool: "NOTION_GET_ABOUT_ME")],
    ]

    /// Any other app: an identity tool found among its tools by the end of its slug, in this order.
    static let identityEndings = ["WHO_AM_I", "GET_CURRENT_USER", "GET_ME", "GET_ABOUT_ME", "GET_PROFILE", "GET_AUTHENTICATED_USER", "GET_ABOUT"]
    /// Keys a name is read from, in this order; the first non-empty value wins.
    static let nameKeys = ["email", "emailAddress", "email_address", "mail", "userPrincipalName", "login", "username", "user_name", "handle",
                           "display_name", "displayName", "real_name", "name"]
    static let slackUserKeys = nameKeys + ["user"]
    static let slackTeamKeys = ["team", "team_name", "workspace", "workspace_name"]
    static let nameLimit = 80, searchDepth = 6

    /// An identity tool of `toolkit` among `tools`: its slug ends with one of `identityEndings`, P52 classifies it as a
    /// read, and it has no required arguments.
    static func discover(in tools: [ComposioTool], toolkit: String) -> Call? {
        let reads = tools.filter {
            $0.toolkit == toolkit && ($0.schema["required"].array ?? []).isEmpty
                && AppToolAccess.classify(slug: $0.slug, toolkit: $0.toolkit, tags: $0.tags) == .read
        }
        for ending in identityEndings {
            if let slug = reads.map(\.slug).filter({ $0.hasSuffix("_" + ending) }).sorted().first { return Call(tool: slug) }
        }
        return nil
    }

    /// The name in an execute result: `data` (decoded when Composio sent it as a JSON string) and everything under it,
    /// searched breadth-first to `searchDepth` for `nameKeys` in order. Slack: "user @ team" when both are there.
    static func read(_ result: ComposioValue, toolkit: String) -> Found? {
        guard result["successful"].bool != false else { return nil }
        let tree = decoded(result)
        if toolkit == "slack", let user = search(slackUserKeys, in: tree, skipping: Set(slackTeamKeys), accept: \.string) {
            let team = search(slackTeamKeys, in: tree) { $0.string ?? $0["name"].string } // a team object: its name
            guard let team, team.name != user.name else { return user }
            return Found(name: String("\(user.name) @ \(team.name)".prefix(nameLimit)), path: "\(user.path) @ \(team.path)")
        }
        return search(nameKeys, in: tree, accept: \.string)
    }

    /// `data` and `response_data` that arrive as JSON strings, decoded (any depth).
    static func decoded(_ value: ComposioValue) -> ComposioValue {
        switch value {
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, field in
                if ["data", "response_data"].contains(key), let text = field.string, let inner = json(text) { return (key, decoded(inner)) }
                return (key, decoded(field))
            }))
        case .array(let items): return .array(items.map(decoded))
        default: return value
        }
    }

    /// Keys and types of the result and of its `data` (P52 `AppFailureShape`), never a value.
    static func shape(_ result: ComposioValue) -> String {
        let tree = decoded(result)
        var text = AppFailureShape.describe(tree)
        if tree["data"].object != nil { text += "; data " + AppFailureShape.describe(tree["data"]) }
        if tree["data"]["response_data"].object != nil { text += "; data.response_data " + AppFailureShape.describe(tree["data"]["response_data"]) }
        return text
    }

    private static func json(_ text: String) -> ComposioValue? {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return nil }
        return try? JSONDecoder().decode(ComposioValue.self, from: Data(text.utf8))
    }

    /// For each key in order, the shallowest usable value under it (keys at one level in sorted order).
    private static func search(_ keys: [String], in tree: ComposioValue, skipping: Set<String> = [], accept: (ComposioValue) -> String?) -> Found? {
        for key in keys {
            var level: [(value: ComposioValue, path: String)] = [(tree, "")]
            for _ in 0...searchDepth where !level.isEmpty {
                var next: [(value: ComposioValue, path: String)] = []
                for (value, path) in level {
                    switch value {
                    case .object(let fields):
                        for name in fields.keys.sorted() {
                            let child = fields[name]!, childPath = path.isEmpty ? name : "\(path).\(name)"
                            if name == key, let text = accept(child).flatMap(clean) { return Found(name: text, path: childPath) }
                            if !skipping.contains(name) { next.append((child, childPath)) }
                        }
                    case .array(let items): next += items.enumerated().map { ($0.element, "\(path)[\($0.offset)]") }
                    default: break
                    }
                }
                level = next
            }
        }
        return nil
    }

    /// Trimmed, one line, at most `nameLimit` characters; nil when empty or several lines.
    static func clean(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        return String(text.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
    }
}

/// P53: one account's identity call: the tool used (nil when the app has none), the name found, else the result's shape.
struct AccountIdentity: Sendable, Equatable {
    let tool: String?; let found: AccountProfileName.Found?; let shape: String
}

extension ConnectedAppsStore {
    static let aliasLimit = 100
    /// P53: an account whose naming failed is tried again on a refresh at least this long after.
    static let namingBackoff: TimeInterval = 600

    /// P53: names every active account that has no alias, on every refresh: the identity call in a single-account session
    /// pinned to that account (SwarmHub's own read, not a bot action, so no approval), then the alias at Composio so the
    /// name survives reinstalls. A failure waits `namingBackoff` before that account is tried again. An alias (Rename…)
    /// is never overwritten.
    func nameUnnamedAccounts(using service: ComposioClient) async {
        for account in accounts where account.isActive && !account.hasName && !namingAccounts.contains(account.id) {
            if let after = namingRetryAfter[account.id], now() < after { continue }
            namingAccounts.insert(account.id); defer { namingAccounts.remove(account.id) }
            do {
                let identity = try await Self.identify(account, userID: configuration.userID, using: service)
                guard let found = identity.found else { throw ComposioError.unreadable(identity.shape) }
                let alias = try await saveAlias(found.name, for: account, using: service)
                namingRetryAfter[account.id] = nil
                if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = accounts[index].withAlias(alias) }
            } catch {
                namingRetryAfter[account.id] = now().addingTimeInterval(Self.namingBackoff)
                ComposioClient.log.error("Naming a \(account.toolkit, privacy: .public) account failed: \(self.describe(error), privacy: .public)")
            }
        }
    }

    /// P53: the identity call for one account (the app's known tools in order, else one found among its tools), in a
    /// single-account session pinned to it. Runs nothing else and writes nothing.
    static func identify(_ account: ComposioAccount, userID: String, using service: ComposioClient) async throws -> AccountIdentity {
        var calls = AccountProfileName.known[account.toolkit] ?? []
        if calls.isEmpty {
            let tools = try await service.toolkitTools(account.toolkit)
            guard let call = AccountProfileName.discover(in: tools, toolkit: account.toolkit) else {
                return AccountIdentity(tool: nil, found: nil, shape: "no read-only identity tool among \(tools.count) tools")
            }
            calls = [call]
        }
        let session = try await service.createSession(userID: userID, toolkits: [account.toolkit], accounts: [account.toolkit: [account.id]])
        defer { Task { await service.deleteSession(session) } }
        var last: AccountIdentity?, lastError: Error?
        for call in calls {
            do {
                let result = try await service.execute(sessionID: session, tool: call.tool, arguments: call.arguments)
                let identity = AccountIdentity(tool: call.tool, found: AccountProfileName.read(result, toolkit: account.toolkit), shape: AccountProfileName.shape(result))
                if identity.found != nil { return identity }
                last = identity
            } catch { lastError = error }
        }
        if let last { return last }
        throw lastError ?? ComposioError.invalidResponse
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

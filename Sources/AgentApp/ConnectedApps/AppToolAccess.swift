import Foundation

/// P52: whether an app tool only reads (runs without asking) or may change something (asks, P37/P48 card). Conservative:
/// anything not clearly a read asks. Rules, first match wins:
/// 1. a Composio tag meaning destructive/write → asks;
/// 2. any word of the tool's action part in `denyWords` → asks;
/// 3. a tag meaning read-only → runs;
/// 4. an action part starting with one of `readStarts` → runs;
/// (a slug that does not start with its app's prefix has no action part: asks, whatever its tags);
/// 5. anything else → asks.
/// A read still asks when its arguments could carry data out (`mayCarryDataOut`): see `access(of:arguments:accountNames:)`.
enum AppToolAccess: String, Sendable, Equatable {
    case read, write

    static let denyWords: Set<String> = [
        "SEND", "CREATE", "UPDATE", "DELETE", "REMOVE", "ADD", "MODIFY", "EDIT", "MOVE", "COPY", "STAR", "UNSTAR", "FOLLOW",
        "UNFOLLOW", "MERGE", "POST", "REPLY", "FORWARD", "TRASH", "ARCHIVE", "LABEL", "MARK", "RUN", "EXECUTE", "QUERY", "PROXY",
        "UPLOAD", "SET", "PATCH", "PUT", "INVITE", "APPROVE", "ACCEPT", "DECLINE", "CANCEL", "CLOSE", "OPEN", "LOCK", "TRANSFER",
        "PAY", "BOOK", "SCHEDULE", "SUBSCRIBE", "ENABLE", "DISABLE", "REVOKE", "GRANT", "DISPATCH", "TRIGGER", "COMMENT", "REACT",
        "PIN", "SAVE", "WRITE",
        // Beyond the brief's list, the same spirit (only ever makes a tool ask): verbs that change or share data.
        "REPLACE", "INSERT", "APPEND", "SHARE", "RENAME", "RESET", "RESTORE", "CLEAR", "IMPORT", "EXPORT", "SYNC", "DRAFT",
        "UNSUBSCRIBE", "ASSIGN", "RESOLVE", "REOPEN",
        // Tools that reach an address the bot names (`X_FETCH_URL`): a request to it can carry data out.
        "URL", "WEBHOOK", "HTTP", "HTTPS", "REQUEST", "CALLBACK", "REDIRECT", "EMBED", "SCRAPE", "CRAWL", "BROWSE", "NAVIGATE",
        "PING", "NOTIFY",
    ]
    /// Each entry is one or more words the action part must start with (`WHO_AM_I` is three).
    static let readStarts: [[String]] = [
        ["GET"], ["LIST"], ["FETCH"], ["SEARCH"], ["FIND"], ["READ"], ["RETRIEVE"], ["LOOKUP"], ["COUNT"], ["CHECK"], ["VALIDATE"],
        ["WHO", "AM", "I"], ["DESCRIBE"], ["DOWNLOAD"],
    ]
    /// Tags compared lower-cased with `_`, `-` and spaces removed.
    static let writeTags: Set<String> = ["destructivehint", "destructive", "writehint", "write"]
    static let readTags: Set<String> = ["readonlyhint", "readonly"]

    static func classify(slug: String, toolkit: String, tags: [String]) -> Self {
        let tags = Set(tags.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } })
        if !tags.isDisjoint(with: writeTags) { return .write }
        let words = actionWords(slug: slug, toolkit: toolkit)
        guard !words.isEmpty, words.allSatisfy({ !denyWords.contains($0) }) else { return .write }
        if !tags.isDisjoint(with: readTags) { return .read }
        return readStarts.contains { words.starts(with: $0) } ? .read : .write
    }

    /// `GITHUB_GET_THE_AUTHENTICATED_USER` of `github` → GET, THE, AUTHENTICATED, USER; empty when the slug does not
    /// start with the toolkit's prefix.
    static func actionWords(slug: String, toolkit: String) -> [String] {
        let words = slug.uppercased().split(separator: "_").map(String.init)
        let prefix = toolkit.uppercased().split(separator: "_").map(String.init)
        guard !prefix.isEmpty, words.starts(with: prefix) else { return [] }
        return Array(words.dropFirst(prefix.count))
    }

    /// Longest argument string a read may carry and still run on its own.
    static let maximumArgumentLength = 2_000
    /// `http://`, `https://`, `ftp://` or any other `//host` form.
    nonisolated(unsafe) static let urlPattern = #/\/\/[^\s\/]/#
    /// Any letters, not only ASCII (`x@żółw.pl`), so the whole address is compared with the account names.
    nonisolated(unsafe) static let emailPattern = #/[^\s@<>()\[\],;:"'\/]+@[^\s@<>()\[\],;:"'\/?#]+\.[^\s@<>()\[\],;:"'\/?#]+/#

    /// True when any string in the arguments (values and keys, searched recursively) holds an address, an email that is
    /// not one of `accountNames` (compared case-insensitively), or more than `maximumArgumentLength` characters.
    static func mayCarryDataOut(_ arguments: ComposioValue, accountNames: Set<String>) -> Bool {
        switch arguments {
        case .object(let values): return values.contains { suspicious($0.key, accountNames) || mayCarryDataOut($0.value, accountNames: accountNames) }
        case .array(let values): return values.contains { mayCarryDataOut($0, accountNames: accountNames) }
        case .string(let text): return suspicious(text, accountNames)
        case .number, .bool, .null: return false
        }
    }

    /// Measured in Unicode scalars (combining marks count); matched after NFKC folding (fullwidth `／`, `＠`), without tabs
    /// and line breaks (URL parsers drop them), with `\` read as `/`, both as written and percent-decoded until stable.
    private static func suspicious(_ text: String, _ accountNames: Set<String>) -> Bool {
        if text.unicodeScalars.count > maximumArgumentLength { return true }
        let own = Set(accountNames.map { $0.precomposedStringWithCompatibilityMapping.lowercased() })
        func fold(_ text: String) -> String {
            String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { !"\t\n\r".unicodeScalars.contains($0) })
                .replacingOccurrences(of: "\\", with: "/")
        }
        var forms = [fold(text)]
        while forms.count < 8, let decoded = forms.last!.removingPercentEncoding.map(fold), decoded != forms.last { forms.append(decoded) }
        return forms.contains { form in
            form.contains(urlPattern) || form.matches(of: emailPattern).contains { !own.contains(String($0.output).lowercased()) }
        }
    }
}

extension ConnectedAppsStore {
    /// P52: each tool is classified once per launch, by slug.
    func access(of tool: ComposioTool) -> AppToolAccess {
        if let known = toolAccess[tool.slug] { return known }
        let access = AppToolAccess.classify(slug: tool.slug, toolkit: tool.toolkit, tags: tool.tags)
        toolAccess[tool.slug] = access
        return access
    }

    /// P52: one call's access: a read whose arguments could carry data out (`AppToolAccess.mayCarryDataOut`) asks.
    func access(of tool: ComposioTool, arguments: ComposioValue, accountNames: Set<String>) -> AppToolAccess {
        access(of: tool) == .read && !AppToolAccess.mayCarryDataOut(arguments, accountNames: accountNames) ? .read : .write
    }
}

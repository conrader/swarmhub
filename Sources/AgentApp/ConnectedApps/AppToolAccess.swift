import Foundation

/// P52: whether an app tool only reads (runs without asking) or may change something (asks, P37/P48 card). Conservative:
/// anything not clearly a read asks. Rules, first match wins:
/// 1. a Composio tag meaning destructive/write → asks;
/// 2. any word of the tool's action part in `denyWords` → asks;
/// 3. a tag meaning read-only → runs;
/// 4. an action part starting with one of `readStarts` → runs;
/// (a slug that does not start with its app's prefix has no action part: asks, whatever its tags);
/// 5. anything else → asks.
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
}

extension ConnectedAppsStore {
    /// P52: each tool is classified once per launch, by slug.
    func access(of tool: ComposioTool) -> AppToolAccess {
        if let known = toolAccess[tool.slug] { return known }
        let access = AppToolAccess.classify(slug: tool.slug, toolkit: tool.toolkit, tags: tool.tags)
        toolAccess[tool.slug] = access
        return access
    }
}

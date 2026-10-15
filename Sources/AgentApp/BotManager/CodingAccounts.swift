import Foundation

/// P31 C: a coding tool or account pool the Accounts sheet manages on a box.
enum CodingTool: String, CaseIterable, Identifiable, Equatable {
    case claude, codex, chatgpt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .chatgpt: "ChatGPT accounts (conversation)"
        }
    }
}

/// What the manager's "Accounts status" recipe reported (op `accounts`). Never a token, an auth file or an email.
struct AccountsReport: Equatable {
    struct Tool: Equatable { var installed: Bool; var version: String?; var loggedIn: Bool }
    /// Hermes's openai-codex pool in the order it is used (`fill_first`); `benchedUntil[i]` is set while entry i is
    /// benched after a usage limit.
    struct Pool: Equatable {
        var labels: [String]; var benchedUntil: [Date?]
        var count: Int { labels.count }
        /// The first entry that is not benched: the one conversation uses now.
        var inUse: Int? { benchedUntil.firstIndex { $0 == nil } }
    }
    var claude: Tool?; var codex: Tool?; var chatgpt: Pool?

    init(claude: Tool? = nil, codex: Tool? = nil, chatgpt: Pool? = nil) { self.claude = claude; self.codex = codex; self.chatgpt = chatgpt }

    init(_ object: [String: Any]) {
        func tool(_ key: String) -> Tool? {
            guard let row = object[key] as? [String: Any], let installed = row["installed"] as? Bool else { return nil }
            let version = (row["version"] as? String).flatMap { Self.isPlain($0, max: 40) ? $0 : nil }
            return Tool(installed: installed, version: installed ? version : nil, loggedIn: installed && row["logged_in"] as? Bool == true)
        }
        claude = tool("claude"); codex = tool("codex")
        if let row = object["chatgpt"] as? [String: Any] {
            let raw = row["labels"] as? [Any] ?? [], count = (row["count"] as? Int) ?? raw.count
            let until = row["benched_until"] as? [Any] ?? []
            let labels = (0..<max(0, min(count, 64))).map { index -> String in
                guard index < raw.count, let label = raw[index] as? String, Self.isPlain(label, max: 40), !label.contains("@") else { return "account \(index + 1)" }
                return label
            }
            chatgpt = Pool(labels: labels, benchedUntil: labels.indices.map { index in
                index < until.count ? (until[index] as? String).flatMap(Self.date) : nil
            })
        }
    }

    static func isPlain(_ text: String, max: Int) -> Bool {
        (1...max).contains(text.count) && text.allSatisfy { $0.isASCII && !$0.isNewline && $0 != "\"" && $0 != "\\" }
    }

    static func date(_ text: String) -> Date? { try? Date(text, strategy: .iso8601) }
}

/// The P31 C recipes in `Resources/BotManager/manager-hermes.md` ("Coding tools and logins"), each sent in a quiet
/// manager turn the chat never shows; each prints the one JSON line the manager returns in its swarmhub block.
enum CodingAccounts {
    static let statusMarker = "Accounts status:"
    static let installMarker = "Install claude and codex"
    static let loginStartMarker = "Log in, step 1"
    static let loginLinkMarker = "Log in, step 2"
    static let checkMarker = "Check a login"
    static let codeMarker = "Claude's one-time code"
    static let logoutMarker = "Log out (claude or codex)"
    /// Where the Accounts sheet puts `swarmhub-claude-login` on the box (the login turn writes it there first).
    static let claudeLoginPath = "~/.hermes/swarmhub/bin/swarmhub-claude-login"
    /// The same end marker as skill installs (`AppStore.heredocEnd`).
    static let heredocEnd = "SWARMHUB_EOF"

    /// A Claude one-time code SwarmHub will put into a command: the characters claude.ai codes use, nothing a shell
    /// would read (the script checks the same set).
    static func isValidClaudeCode(_ code: String) -> Bool {
        (8...512).contains(code.count) && code.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "#_.~+/=-".contains($0)) }
    }

    static func statusInstructions(template: String) -> String? {
        recipe(statusMarker, template).map { turn("SwarmHub is reading the coding tools and accounts on this box. Reading needs no confirmation.", [("", $0)]) }
    }

    static func installInstructions(template: String) -> String? {
        guard let install = recipe(installMarker, template), let status = recipe(statusMarker, template) else { return nil }
        return turn("Konrad pressed Install in SwarmHub's Accounts sheet: that press is his yes.",
                    [("Start this as a background process of your terminal tool and wait for it to finish:", install), ("Then run:", status)])
    }

    /// Log in: for Claude, `script` (the bundled swarmhub-claude-login) is written to `claudeLoginPath` first.
    static func loginInstructions(_ tool: CodingTool, template: String, script: String? = nil) -> String? {
        guard let start = recipe(loginStartMarker, template), let link = recipe(loginLinkMarker, template) else { return nil }
        var steps: [(String, String)] = []
        if tool == .claude {
            guard let script, !script.contains(heredocEnd) else { return nil }
            steps.append(("First run:", "mkdir -p ~/.hermes/swarmhub/bin && chmod 700 ~/.hermes/swarmhub && cat > \(claudeLoginPath) <<'\(heredocEnd)'\n\(script)\(heredocEnd)\nchmod 700 \(claudeLoginPath)"))
        }
        steps.append(("Start this as a background process of your terminal tool (it keeps running while Konrad signs in):", fill(start, tool)))
        steps.append(("Then run:", fill(link, tool)))
        return turn("Konrad pressed Log in for \(tool.title) in SwarmHub's Accounts sheet: that press is his yes.", steps)
    }

    static func checkInstructions(_ tool: CodingTool, template: String) -> String? {
        recipe(checkMarker, template).map { turn("SwarmHub is checking whether Konrad finished signing in. Reading needs no confirmation.", [("", fill($0, tool))]) }
    }

    /// The hidden code turn; nil for a code SwarmHub would not put into a command.
    static func codeInstructions(_ code: String, template: String) -> String? {
        guard isValidClaudeCode(code), let recipe = recipe(codeMarker, template) else { return nil }
        return turn("Konrad typed Claude's one-time login code into SwarmHub. Never repeat, quote or store the code.",
                    [("", recipe.replacingOccurrences(of: "<code>", with: code))])
    }

    static func logoutInstructions(_ tool: CodingTool, template: String) -> String? {
        guard tool != .chatgpt, let logout = recipe(logoutMarker, template), let status = recipe(statusMarker, template) else { return nil }
        return turn("Konrad pressed Log out for \(tool.title) in SwarmHub's Accounts sheet: that press is his yes.",
                    [("", logout.replacingOccurrences(of: "<tool>", with: tool.rawValue)), ("Then run:", status)])
    }

    private static func recipe(_ marker: String, _ template: String) -> String? { BoxAdoption.recipe(marker, in: template) }
    private static func fill(_ recipe: String, _ tool: CodingTool) -> String { recipe.replacingOccurrences(of: "<tool>", with: tool.rawValue) }

    private static func turn(_ lead: String, _ steps: [(String, String)]) -> String {
        let body = steps.map { ($0.0.isEmpty ? "" : $0.0 + "\n") + "````sh\n\($0.1)\n````" }.joined(separator: "\n")
        return """
        \(lead) Run exactly these commands in your terminal with the shell (not the file tool), change nothing else, then \
        reply in one short line and end with a swarmhub block holding exactly the JSON line the last one printed. Never \
        show a token, a key, an email or a login code.
        \(body)
        """
    }
}

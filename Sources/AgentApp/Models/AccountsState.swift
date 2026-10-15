import Foundation

/// P31 C: the Accounts sheet of one Hermes connection: the manager's last `accounts` report, the one manager turn
/// running, the login links shown and a plain problem line. Every change goes through `begin`/`finish`/`absorb`.
struct AccountsState: Equatable {
    enum Action: Equatable {
        case refresh, install, login(CodingTool), check(CodingTool), code, logout(CodingTool)
        var tool: CodingTool? {
            switch self {
            case .login(let tool), .check(let tool), .logout(let tool): tool
            case .code: .claude
            case .refresh, .install: nil
            }
        }
    }
    enum Phase: Equatable { case unknown, missing, loggedOut, loggedIn }
    /// A login waiting for Konrad: the page to open and (Codex, ChatGPT) the device code to type there.
    struct Link: Equatable { var url: URL; var code: String? }

    var report: AccountsReport?
    var reportedAt: Date?
    var running: Action?
    var links: [CodingTool: Link] = [:]
    var problem: String?
    /// The last check found the login still waiting for Konrad.
    var stillWaiting: Set<CodingTool> = []

    func phase(_ tool: CodingTool) -> Phase {
        guard let report else { return .unknown }
        if tool == .chatgpt { return report.chatgpt.map { $0.count > 0 ? .loggedIn : .loggedOut } ?? .unknown }
        guard let row = tool == .claude ? report.claude : report.codex else { return .unknown }
        return !row.installed ? .missing : row.loggedIn ? .loggedIn : .loggedOut
    }

    /// Whether `action` may start now: one turn at a time; Install only while a tool is missing; Log in only when
    /// installed (ChatGPT: always, it adds an account); Log out only when logged in; a code only while Claude's link shows.
    func allows(_ action: Action) -> Bool {
        guard running == nil else { return false }
        switch action {
        case .refresh: return true
        case .install: return phase(.claude) == .missing || phase(.codex) == .missing
        case .login(let tool): return tool == .chatgpt || phase(tool) == .loggedOut
        case .check(let tool): return links[tool] != nil
        case .code: return links[.claude] != nil
        case .logout(let tool): return tool != .chatgpt && phase(tool) == .loggedIn
        }
    }

    @discardableResult mutating func begin(_ action: Action) -> Bool {
        guard allows(action) else { return false }
        running = action; problem = nil
        if let tool = action.tool { stillWaiting.remove(tool) }
        if case .login(let tool) = action { links[tool] = nil }
        return true
    }

    /// The turn's ops (nil: the manager did not answer).
    mutating func finish(_ action: Action, ops: [SwarmhubOp]?, at time: Date) {
        running = nil
        guard let ops else { problem = AccountsCopy.noAnswer; return }
        absorb(ops, at: time)
        switch action {
        case .refresh, .logout:
            if !ops.contains(where: { if case .accounts = $0 { true } else { false } }) { problem = AccountsCopy.noReport }
        case .install:
            if phase(.claude) == .missing || phase(.codex) == .missing { problem = AccountsCopy.installFailed }
        case .login(let tool):
            if links[tool] == nil, problem == nil { problem = AccountsCopy.noLink(tool) }
        case .check(let tool):
            if !ops.contains(where: { if case .loginDone(tool, _, _) = $0 { true } else { false } }) { problem = AccountsCopy.noReport }
        case .code:
            if !ops.contains(where: { if case .loginDone(.claude, _, _) = $0 { true } else { false } }) { problem = AccountsCopy.noReport }
        }
    }

    /// Ops from a quiet turn or from the manager's chat.
    mutating func absorb(_ ops: [SwarmhubOp], at time: Date) {
        for op in ops {
            switch op {
            case .accounts(let report):
                self.report = report; reportedAt = time
            case .loginLink(let tool, let url, let code):
                links[tool] = Link(url: url, code: tool == .claude ? nil : code)
            case .loginDone(let tool, _, true):
                stillWaiting.insert(tool)
            case .loginDone(let tool, let ok, false):
                links[tool] = nil
                if ok { markLoggedIn(tool) } else { problem = AccountsCopy.loginFailed(tool) }
            default: break
            }
        }
    }

    private mutating func markLoggedIn(_ tool: CodingTool) {
        switch tool {
        case .claude: report?.claude?.loggedIn = true
        case .codex: report?.codex?.loggedIn = true
        case .chatgpt: break   // the refresh after it reads the pool
        }
    }
}

/// The sheet's plain copy.
enum AccountsCopy {
    static let title = "Accounts"
    static let intro = "Coding tools and ChatGPT accounts on this box. The manager bot installs and logs in; tokens stay on the box and are never shown here."
    static let noManager = "No bot on this connection can manage the box yet."
    static let noAnswer = "The manager bot didn’t answer. Try again."
    static let noReport = "The manager bot didn’t report back. Try Refresh."
    static let installFailed = "Install didn’t finish. Try again, or check that Node and npm work on the box."
    static let badCode = "That doesn’t look like a Claude login code."
    static let notChecked = "Not checked yet. Press Refresh."
    static let chatgptHelp = "Conversation uses these accounts in order; the next one is used only after a usage limit."
    static func noLink(_ tool: CodingTool) -> String { "\(tool.title) didn’t give a login link. Try again." }
    static func loginFailed(_ tool: CodingTool) -> String {
        tool == .claude ? "Claude Code didn’t accept the login. Log in again for a new link." : "Signing in to \(tool.title) didn’t finish. Log in again for a new code."
    }
    static func waiting(_ tool: CodingTool) -> String { "Not signed in yet. Finish in the browser, then press Check." }

    static func status(_ tool: CodingTool, _ state: AccountsState, now: Date = .now) -> String {
        let report = state.report
        switch (tool, state.phase(tool)) {
        case (_, .unknown): return notChecked
        case (_, .missing): return "Not installed"
        case (.chatgpt, .loggedOut): return "No accounts"
        case (.chatgpt, _):
            guard let pool = report?.chatgpt else { return notChecked }
            var parts = ["\(pool.count) account\(pool.count == 1 ? "" : "s")"]
            if let index = pool.inUse { parts.append("using \(pool.labels[index])") } else { parts.append("all resting after usage limits") }
            for (index, until) in pool.benchedUntil.enumerated() {
                if let until { parts.append("\(pool.labels[index]) resting until \(until.formatted(date: until.timeIntervalSince(now) > 86_400 ? .abbreviated : .omitted, time: .shortened))") }
            }
            return parts.joined(separator: " · ")
        case (_, let phase):
            let row = tool == .claude ? report?.claude : report?.codex
            let version = row?.version.map { " · \($0)" } ?? ""
            return (phase == .loggedIn ? "Logged in" : "Installed, not logged in") + version
        }
    }
}

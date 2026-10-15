import Foundation

/// P31 C: coding tools and account logins on a box, through the connection's manager bot (Hermes unchanged). Every
/// action is one quiet manager turn (`quietBoxTurn`): a fresh session the chat never shows, its reply never stored or
/// logged; only the swarmhub block's ops are read. Claude's one-time code travels only in such a turn.
extension AppStore {
    static let claudeLoginScript = "scripts/swarmhub-claude-login"

    /// Each Hermes connection with a connected bot, in sidebar order: (connection, host for display).
    var hermesConnections: [(target: String, host: String)] {
        var seen: [String] = []
        for bot in bots where bot.backend == .hermes && !bot.isDemo && !bot.isReadOnlyArchive && !bot.isGrokHistoryOnly && !bot.retiredOnBox {
            let target = connection(of: bot)
            if !seen.contains(target) { seen.append(target) }
        }
        return seen.map { ($0, URL(string: $0)?.host ?? $0) }
    }

    func accounts(on target: String) -> AccountsState { codingAccounts[target] ?? AccountsState() }

    /// The bundled `swarmhub-claude-login` the Claude login turn writes to the box.
    var bundledClaudeLoginScript: String? {
        skillLibrary.first { $0.name == "swarmhub-coding" }?.files.first { $0.path == Self.claudeLoginScript }?.content
    }

    /// Runs one Accounts action on `target` and applies its ops. After a Codex/ChatGPT link it waits for the sign-in
    /// (one check turn); after a finished login it reads the accounts again. False when it could not start.
    @discardableResult func runAccounts(_ action: AccountsState.Action, on target: String, code: String? = nil) async -> Bool {
        var state = accounts(on: target)
        guard state.allows(action) else { return false }
        guard let manager = ensureManager(on: target), manager.backend == .hermes, let backend = try? backend(for: manager),
              let template = managerRecipeTemplate(.accounts) else {
            state.problem = AccountsCopy.noManager; codingAccounts[target] = state; return false
        }
        let instructions: String?
        switch action {
        case .refresh: instructions = CodingAccounts.statusInstructions(template: template)
        case .install: instructions = CodingAccounts.installInstructions(template: template)
        case .login(let tool): instructions = CodingAccounts.loginInstructions(tool, template: template, script: tool == .claude ? bundledClaudeLoginScript : nil)
        case .check(let tool): instructions = CodingAccounts.checkInstructions(tool, template: template)
        case .code: instructions = code.flatMap { CodingAccounts.codeInstructions($0, template: template) }
        case .logout(let tool): instructions = CodingAccounts.logoutInstructions(tool, template: template)
        }
        guard let instructions else {
            if action == .code { state.problem = AccountsCopy.badCode; codingAccounts[target] = state }
            return false
        }
        state.begin(action); codingAccounts[target] = state
        let ops = await quietBoxTurn(backend, persona: manager.persona, request: Self.accountsRequest(action), instructions: instructions)
        var after = accounts(on: target)
        after.finish(action, ops: ops, at: now())
        codingAccounts[target] = after
        switch action {
        case .login(let tool) where tool != .claude && after.links[tool] != nil:
            await runAccounts(.check(tool), on: target)
        case .check(let tool) where after.links[tool] == nil && after.problem == nil:
            await runAccounts(.refresh, on: target)
        case .code where after.links[.claude] == nil && after.problem == nil:
            await runAccounts(.refresh, on: target)
        default: break
        }
        return true
    }

    /// The short visible request of each quiet turn (never the code).
    static func accountsRequest(_ action: AccountsState.Action) -> String {
        switch action {
        case .refresh: "Report the coding tools and accounts on this box for \(AppConstants.name)."
        case .install: "Install Claude Code and Codex CLI on this box."
        case .login(let tool): "Start the \(tool.title) login."
        case .check(let tool): "Check the \(tool.title) login."
        case .code: "Hand Claude Code its one-time login code."
        case .logout(let tool): "Log \(tool.title) out on this box."
        }
    }
}

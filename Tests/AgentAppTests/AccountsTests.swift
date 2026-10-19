import Foundation
import Testing
@testable import AgentApp

// P31 C: the Accounts sheet: the accounts/login_link/login_done ops, the recipes filled per turn, the sheet's state
// machine, the store's quiet manager turns (Claude's code never in a chat, a message or a request's visible input), and
// the shell tests of swarmhub-claude-login and the manager-text recipes under /bin/sh and /bin/dash. Synthetic only.

private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
private func block(_ json: String) -> String { "Done.\n```swarmhub\n\(json)\n```" }
private func ops(_ json: String) -> [SwarmhubOp] { SwarmhubBlock.ops(in: block(json)) ?? [] }
private let claudeLink = "https://claude.ai/oauth/authorize?code=true&client_id=c&state=s"
private let missing = #"{"op":"accounts","claude":{"installed":false,"version":null,"logged_in":false},"codex":{"installed":false,"version":null,"logged_in":false},"chatgpt":{"count":0,"labels":[],"benched_until":[]}}"#
private let loggedOut = #"{"op":"accounts","claude":{"installed":true,"version":"2.1.3","logged_in":false},"codex":{"installed":true,"version":"0.50.1","logged_in":false},"chatgpt":{"count":1,"labels":["main"],"benched_until":[null]}}"#
private let loggedIn = #"{"op":"accounts","claude":{"installed":true,"version":"2.1.3","logged_in":true},"codex":{"installed":true,"version":"0.50.1","logged_in":true},"chatgpt":{"count":2,"labels":["main","account 2"],"benched_until":["2026-10-15T14:00:00Z",null]}}"#

// MARK: Ops

@Test func accountsOpReadsToolsAndThePoolWithoutEmails() throws {
    let parsed = ops(#"{"op":"accounts","claude":{"installed":true,"version":"2.1.3","logged_in":true},"codex":{"installed":false,"version":"9","logged_in":true},"chatgpt":{"count":3,"labels":["konrad@example.com","work","a\"b"],"benched_until":["2026-10-15T14:00:00Z",null],"access_token":"SECRET"}}"#)
    guard case .accounts(let report)? = parsed.first else { Issue.record("no accounts op"); return }
    #expect(report.claude == .init(installed: true, version: "2.1.3", loggedIn: true))
    #expect(report.codex == .init(installed: false, version: nil, loggedIn: false), "not installed is never logged in")
    let pool = try #require(report.chatgpt)
    #expect(pool.labels == ["account 1", "work", "account 3"], "emails and odd labels become plain names")
    #expect(pool.benchedUntil == [try Date("2026-10-15T14:00:00Z", strategy: .iso8601), nil, nil] && pool.inUse == 1)
}

@Test func loginOpsAcceptOnlyTheToolsOwnHttpsHosts() {
    #expect(ops(#"{"op":"login_link","tool":"codex","url":"https://auth.openai.com/codex/device","code":"ABCD-1234"}"#)
            == [.loginLink(tool: .codex, url: URL(string: "https://auth.openai.com/codex/device")!, code: "ABCD-1234")])
    #expect(ops(#"{"op":"login_link","tool":"claude","url":"\#(claudeLink)"}"#) == [.loginLink(tool: .claude, url: URL(string: claudeLink)!, code: nil)])
    for bad in [#""tool":"codex","url":"http://auth.openai.com/x""#, #""tool":"codex","url":"https://evil.example/auth.openai.com""#,
                #""tool":"claude","url":"https://auth.openai.com/x""#, #""tool":"codex","url":"https://auth.openai.com.evil.example/x""#,
                #""tool":"codex","url":"https://me@auth.openai.com/x""#, #""tool":"gemini","url":"https://auth.openai.com/x""#] {
        #expect(ops(#"{"op":"login_link",\#(bad)}"#).isEmpty, "\(bad)")
    }
    if case .loginLink(_, _, let code)? = ops(#"{"op":"login_link","tool":"codex","url":"https://auth.openai.com/d","code":"AB; rm -rf"}"#).first { #expect(code == nil) }
    #expect(ops(#"{"op":"login_done","tool":"claude","ok":true}"#) == [.loginDone(tool: .claude, ok: true, pending: false)])
    #expect(ops(#"{"op":"login_done","tool":"codex","ok":false,"pending":true}"#) == [.loginDone(tool: .codex, ok: false, pending: true)])
}

// MARK: Recipes

@Test func eachActionIsTheManagerTextsRecipeFilledForOneTurn() throws {
    let template = try #require(BotManagerText.recipe(.accounts))
    let status = try #require(CodingAccounts.statusInstructions(template: template))
    #expect(status.contains(#"op:"accounts""#) && status.contains("swarmhub block"))
    #expect(try #require(CodingAccounts.installInstructions(template: template)).contains("npm install -g --prefix ~/.local @anthropic-ai/claude-code @openai/codex"))
    let codex = try #require(CodingAccounts.loginInstructions(.codex, template: template))
    #expect(codex.contains("T=codex;") && codex.contains("background process") && !codex.contains("<tool>") && !codex.contains("SWARMHUB_EOF"))
    #expect(CodingAccounts.loginInstructions(.claude, template: template, script: nil) == nil, "Claude needs the script")
    let script = "#!/bin/sh\necho hi\n"
    let claude = try #require(CodingAccounts.loginInstructions(.claude, template: template, script: script))
    #expect(claude.contains("cat > ~/.hermes/swarmhub/bin/swarmhub-claude-login <<'SWARMHUB_EOF'\n\(script)SWARMHUB_EOF\nchmod 700"))
    #expect(CodingAccounts.loginInstructions(.claude, template: template, script: "x\nSWARMHUB_EOF\n") == nil)
    let code = try #require(CodingAccounts.codeInstructions("good-code#st8", template: template))
    #expect(code.contains("swarmhub-claude-login code 'good-code#st8'") && code.contains("Never repeat"))
    for bad in ["short", "has space here", "quote'here12", "semi;colon12", "$(reboot)xyz"] { #expect(CodingAccounts.codeInstructions(bad, template: template) == nil, "\(bad)") }
    #expect(CodingAccounts.logoutInstructions(.chatgpt, template: template) == nil, "the pool is shared by every bot: no log out")
    #expect(try #require(CodingAccounts.logoutInstructions(.codex, template: template)).contains("case codex in"))
}

// MARK: State machine

@Test func sheetGoesFromMissingThroughInstallAndClaudesCodeToLoggedIn() throws {
    var state = AccountsState(); let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    #expect(state.phase(.claude) == .unknown && !state.allows(.install) && state.allows(.refresh))
    let began = state.begin(.refresh)
    #expect(began && !state.allows(.refresh), "one turn at a time")
    state.finish(.refresh, ops: ops(missing), at: t0)
    #expect(state.phase(.claude) == .missing && state.phase(.codex) == .missing && state.phase(.chatgpt) == .loggedOut && state.reportedAt == t0)
    #expect(!state.allows(.login(.claude)) && state.allows(.install) && state.allows(.login(.chatgpt)))
    state.begin(.install); state.finish(.install, ops: ops(loggedOut), at: t0)
    #expect(state.phase(.claude) == .loggedOut && state.problem == nil && !state.allows(.install) && !state.allows(.code))
    state.begin(.login(.claude)); state.finish(.login(.claude), ops: ops(#"{"op":"login_link","tool":"claude","url":"\#(claudeLink)"}"#), at: t0)
    #expect(state.links[.claude] == .init(url: URL(string: claudeLink)!, code: nil) && state.allows(.code))
    state.begin(.code); state.finish(.code, ops: ops(#"{"op":"login_done","tool":"claude","ok":true}"#), at: t0)
    #expect(state.phase(.claude) == .loggedIn && state.links[.claude] == nil && state.allows(.logout(.claude)) && !state.allows(.logout(.chatgpt)))
    state.finish(.refresh, ops: ops(loggedIn), at: t0)
    #expect(AccountsCopy.status(.claude, state) == "Logged in · 2.1.3")
    #expect(AccountsCopy.status(.chatgpt, state, now: t0).hasPrefix("2 accounts · using account 2 · main resting until "))
}

@Test func codexDeviceCodeWaitsThenFinishes() {
    var state = AccountsState(); let t0 = Date()
    state.finish(.refresh, ops: ops(loggedOut), at: t0)
    state.begin(.login(.codex)); state.finish(.login(.codex), ops: ops(#"{"op":"login_link","tool":"codex","url":"https://auth.openai.com/codex/device","code":"ABCD-1234"}"#), at: t0)
    #expect(state.links[.codex]?.code == "ABCD-1234" && !state.allows(.code), "the code field is Claude's only")
    state.begin(.check(.codex)); state.finish(.check(.codex), ops: ops(#"{"op":"login_done","tool":"codex","ok":false,"pending":true}"#), at: t0)
    #expect(state.links[.codex] != nil && state.stillWaiting == [.codex] && state.problem == nil)
    state.begin(.check(.codex)); state.finish(.check(.codex), ops: ops(#"{"op":"login_done","tool":"codex","ok":true}"#), at: t0)
    #expect(state.phase(.codex) == .loggedIn && state.links[.codex] == nil && state.stillWaiting.isEmpty)
}

@Test func failuresLeaveAPlainLineAndNoStaleLink() {
    var state = AccountsState(); let t0 = Date()
    state.begin(.refresh); state.finish(.refresh, ops: nil, at: t0)
    #expect(state.problem == AccountsCopy.noAnswer && state.running == nil)
    state.finish(.refresh, ops: ops(missing), at: t0)
    state.begin(.install); state.finish(.install, ops: ops(missing), at: t0)
    #expect(state.problem == AccountsCopy.installFailed)
    state.finish(.refresh, ops: ops(loggedOut), at: t0)
    state.begin(.login(.claude)); state.finish(.login(.claude), ops: ops(#"{"op":"login_done","tool":"claude","ok":false}"#), at: t0)
    #expect(state.problem == AccountsCopy.loginFailed(.claude) && state.links[.claude] == nil)
    state.begin(.login(.claude)); state.finish(.login(.claude), ops: [], at: t0)
    #expect(state.problem == AccountsCopy.noLink(.claude))
    state.begin(.login(.claude)); state.finish(.login(.claude), ops: ops(#"{"op":"login_link","tool":"claude","url":"\#(claudeLink)"}"#), at: t0)
    state.begin(.code); state.finish(.code, ops: ops(#"{"op":"login_done","tool":"claude","ok":false}"#), at: t0)
    #expect(state.problem == AccountsCopy.loginFailed(.claude) && state.links[.claude] == nil && state.phase(.claude) == .loggedOut && !state.allows(.code))
}

// MARK: Store: quiet turns

/// Jarvis manages a synthetic box; each chat turn gets the next reply.
@MainActor private func accountsStore(url: URL = temporaryStore(), replies: [String]) -> (AppStore, Bot, String) {
    let counter = LockedTrace()
    let (chat, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-acc"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes },
                         keyStore: InMemoryKeyStore(["hermes": "default-key", "hermes.grok-jarvis": "manager-key"]), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, chat)
}

private func turns(_ host: String) -> [(input: String, instructions: String)] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { ($0.body?["input"] as? String ?? "", $0.body?["instructions"] as? String ?? "") }
}

@Test @MainActor func claudeLoginRunsInQuietTurnsAndTheCodeNeverReachesAChat() async throws {
    let secret = "s3cret-Code#st8xyz", url = temporaryStore()
    let (store, jarvis, chat) = accountsStore(url: url, replies: [block(missing), block(loggedOut), block(#"{"op":"login_link","tool":"claude","url":"\#(claudeLink)"}"#),
                                                         "Sent.\n```swarmhub\n{\"op\":\"login_done\",\"tool\":\"claude\",\"ok\":true}\n```", block(loggedIn)])
    let target = store.connection(of: jarvis)
    #expect(store.hermesConnections.map(\.target) == [target])
    #expect(await store.runAccounts(.refresh, on: target) && store.accounts(on: target).phase(.claude) == .missing)
    #expect(await store.runAccounts(.install, on: target) && store.accounts(on: target).phase(.claude) == .loggedOut)
    #expect(await store.runAccounts(.login(.claude), on: target) && store.accounts(on: target).links[.claude] != nil)
    #expect(await store.runAccounts(.code, on: target, code: secret))
    let state = store.accounts(on: target)
    #expect(state.phase(.claude) == .loggedIn && state.phase(.chatgpt) == .loggedIn && state.running == nil, "the code's ok is followed by a refresh")
    let sent = turns(chat)
    #expect(sent.count == 5)
    #expect(sent[2].instructions.contains("cat > ~/.hermes/swarmhub/bin/swarmhub-claude-login <<'SWARMHUB_EOF'\n#!/bin/sh"), "the bundled script goes with the login turn")
    #expect(sent.filter { $0.instructions.contains(secret) }.count == 1 && sent[3].input == AppStore.accountsRequest(.code), "the code only in the code turn's instructions")
    #expect(!sent.contains { $0.input.contains(secret) })
    #expect(jarvis.messages.isEmpty && store.bots.allSatisfy { bot in !bot.messages.contains { $0.content.contains(secret) || $0.content.contains("swarmhub-claude-login") } },
            "quiet turns never land in a chat")
    store.save()
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(!saved.contains(secret) && !saved.contains(claudeLink), "nothing of the login is persisted")
}

@Test @MainActor func badCodeIsRefusedWithoutATurnAndChatRepliesCannotPlantALink() async throws {
    let (store, jarvis, chat) = accountsStore(replies: [block(loggedOut), block(#"{"op":"login_link","tool":"claude","url":"\#(claudeLink)"}"#)])
    let target = store.connection(of: jarvis)
    await store.runAccounts(.refresh, on: target); await store.runAccounts(.login(.claude), on: target)
    #expect(await store.runAccounts(.code, on: target, code: "x'; rm -rf ~ #") == false)
    #expect(store.accounts(on: target).problem == AccountsCopy.badCode && turns(chat).count == 2)
    // A manager chat reply with a login link (e.g. injected text) is ignored; an accounts report is taken.
    var fresh = AccountsState(); fresh.finish(.refresh, ops: ops(loggedOut), at: .now); store.codingAccounts[target] = fresh
    await store.apply(.loginLink(tool: .claude, url: URL(string: claudeLink)!, code: nil), manager: jarvis)
    await store.apply(.loginDone(tool: .codex, ok: true, pending: false), manager: jarvis)
    #expect(store.accounts(on: target).links.isEmpty && store.accounts(on: target).phase(.codex) == .loggedOut)
    if case .accounts(let report)? = ops(loggedIn).first { await store.apply(.accounts(report), manager: jarvis) }
    #expect(store.accounts(on: target).phase(.codex) == .loggedIn)
}

@Test @MainActor func codexLinkIsFollowedByOneWaitingCheck() async {
    let (store, jarvis, chat) = accountsStore(replies: [block(loggedOut), block(#"{"op":"login_link","tool":"codex","url":"https://auth.openai.com/codex/device","code":"ABCD-1234"}"#),
                                                         block(#"{"op":"login_done","tool":"codex","ok":false,"pending":true}"#)])
    let target = store.connection(of: jarvis)
    await store.runAccounts(.refresh, on: target); await store.runAccounts(.login(.codex), on: target)
    let state = store.accounts(on: target)
    #expect(state.links[.codex]?.code == "ABCD-1234" && state.stillWaiting == [.codex] && turns(chat).count == 3)
    #expect(turns(chat)[2].instructions.contains("T=codex; F=~/.hermes/swarmhub/$T-login.out"))
}

// MARK: Shell tests

private func runShellTest(_ script: String, _ args: [String], shell: String, env: [String: String]) async throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = [repoRoot.appending(path: script).path] + args
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path].merging(env) { $1 }
    return try await runToEnd(process)
}

/// `Tests/Scripts/claude-login-test.sh`: a stub claude in a pseudo-terminal; the token only in the 0600 file.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func claudeLoginShellTestPasses(_ shell: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return }
    let (status, output) = try await runShellTest("Tests/Scripts/claude-login-test.sh", [repoRoot.appending(path: "Resources/Skills/swarmhub-coding/scripts/swarmhub-claude-login").path],
                                            shell: shell, env: ["LOGIN_SH": shell])
    #expect(status == 0 && output.contains("claude-login tests under \(shell): 5 passed, 0 failed") && !output.contains("FAIL"), "\(output)")
}

/// `Tests/Scripts/accounts-recipes-test.sh`: the recipes/accounts.md recipes with stub CLIs; needs node, as the box has.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func accountsRecipesShellTestPasses(_ shell: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: shell),
          let node = ["/opt/homebrew/bin", "/usr/local/bin"].first(where: { FileManager.default.isExecutableFile(atPath: "\($0)/node") }) else { return }
    let (status, output) = try await runShellTest("Tests/Scripts/accounts-recipes-test.sh", [repoRoot.appending(path: "Resources/BotManager/recipes/accounts.md").path, node],
                                            shell: shell, env: ["BOX_SH": shell])
    if shellSuiteSkipped(status, output) { return }
    #expect(status == 0 && output.contains("accounts recipe tests under \(shell): 6 passed, 0 failed") && !output.contains("FAIL"), "\(output)")
}

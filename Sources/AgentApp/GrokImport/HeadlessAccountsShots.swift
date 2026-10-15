import AppKit
import SwiftUI

/// P31 C shots of `--render-setup`: the Accounts sheet with nothing installed, Claude's link and code field, Codex's
/// device code, and everything logged in with a two-account ChatGPT pool, one resting after a usage limit. Synthetic
/// store states; no turn runs.
@MainActor enum HeadlessAccountsShots {
    static let names = ["p31c-accounts-missing", "p31c-accounts-claude", "p31c-accounts-codex-code", "p31c-accounts-logged-in"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
        jarvis.canManageBots = true; jarvis.hermesBaseURL = "https://box.example.net"
        store.bots = [jarvis]
        let target = AccountsTarget(id: store.connection(of: jarvis), host: "box.example.net")
        let reset = Date().addingTimeInterval(2 * 3600)
        let tool = { (installed: Bool, version: String, loggedIn: Bool) in AccountsReport.Tool(installed: installed, version: installed ? version : nil, loggedIn: loggedIn) }
        var states: [AccountsState] = []
        var missing = AccountsState(); missing.report = AccountsReport(claude: tool(false, "", false), codex: tool(false, "", false), chatgpt: .init(labels: [], benchedUntil: []))
        states.append(missing)
        var claude = AccountsState(); claude.report = AccountsReport(claude: tool(true, "2.1.3", false), codex: tool(true, "0.50.1", false), chatgpt: .init(labels: ["main"], benchedUntil: [nil]))
        claude.links[.claude] = .init(url: URL(string: "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&state=Qx3")!, code: nil)
        states.append(claude)
        var codex = claude; codex.links = [.codex: .init(url: URL(string: "https://auth.openai.com/codex/device")!, code: "K7QF-29XM")]; codex.stillWaiting = [.codex]
        states.append(codex)
        var all = AccountsState(); all.report = AccountsReport(claude: tool(true, "2.1.3", true), codex: tool(true, "0.50.1", true), chatgpt: .init(labels: ["main", "account 2"], benchedUntil: [reset, nil]))
        states.append(all)
        for (name, state) in zip(names, states) {
            store.codingAccounts[target.id] = state
            write(name, await png(AnyView(AccountsSheet(target: target, refreshesOnAppear: false).background(AppColor.panel)), store, NSSize(width: 560, height: name == names[1] || name == names[2] ? 470 : 330)))
        }
    }
}

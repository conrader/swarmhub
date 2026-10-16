import AppKit
import SwiftUI

/// P47 shots of `--render-setup` (alone with `--only p47`): the sidebar at its narrowest (240 pt) in light and dark with
/// Connect apps at the bottom left above the initial + Settings bar, and Settings → Connected apps right after Slack was
/// connected there (on for all bots, the line saying so, the toggles on). Composio answers come from an in-process
/// protocol and the key from memory: no network, no Keychain, no browser.
@MainActor enum HeadlessP47Shots {
    static let names = ["p47-sidebar-light", "p47-sidebar-dark", "p47-settings-apps-after-connect"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize, ColorScheme) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let cfo = Bot(name: "Cfo", title: "Budgets and invoices", backend: .hermes, hermesProfile: "cfo")
        let reactor = Bot(name: "Reactor", title: "Daily ops", backend: .hermes, hermesProfile: "reactor")
        for (index, bot) in [jarvis, cfo, reactor].enumerated() { bot.avatarName = BotAvatarName.allCases[index % BotAvatarName.allCases.count] }
        store.bots = [jarvis, cfo, reactor]; store.selectedBot = jarvis

        // 1–2. The sidebar at its minimum width.
        let sidebar = NSSize(width: SidebarMetrics.width.min, height: 560)
        let column = SidebarView(selection: .constant(jarvis)).frame(width: sidebar.width, height: sidebar.height)
        write(names[0], await png(AnyView(column), store, sidebar, .light))
        write(names[1], await png(AnyView(column), store, sidebar, .dark))

        // 3. Settings → Connected apps: Jarvis already had Work Gmail; Slack is connected from the pane and appears on return.
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [P47ComposioProtocol.self]
        let keys = MemoryKeyStore(); keys.setKey("synthetic-render-key", for: ConnectedAppsStore.keyAccount)
        let apps = ConnectedAppsStore(directory: store.fileURL.deletingLastPathComponent().appending(path: "p47"), keyStore: keys,
                                      session: URLSession(configuration: configuration), apiURL: P47ComposioProtocol.base)
        P47ComposioProtocol.connected = false
        await apps.refresh()
        if let work = apps.accounts.first { apps.setAllowed(true, account: work, botID: jarvis.id) }
        _ = await apps.connect("slack", grantingTo: store.connectedAppsBots.map(\.id))
        P47ComposioProtocol.connected = true
        await apps.refresh()
        store.connectedApps = apps
        let chatGPT = ChatGPTConnection(makeClient: { P47SignedOutCodex() }, openURL: { _ in false })
        let panel = NSSize(width: 760, height: 1180)
        let pane = Form { SettingsConnectedAppsPane(apps: apps, chatGPT: chatGPT, checksOnAppear: false) }.formStyle(.grouped).background(AppColor.panel)
        write(names[2], await png(AnyView(pane.frame(width: panel.width, height: panel.height)), store, panel, .light))
    }
}

/// Renders only: a ChatGPT account that is not signed in (no Codex process).
@MainActor private final class P47SignedOutCodex: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        method == "account/read" ? .object(["account": .null]) : .object([:])
    }
    func close(stopping threadID: String?) { onNotification = nil; onClose = nil }
}

/// Renders only: synthetic Composio answers served in-process. Work Gmail exists; Team Slack appears once `connected`.
final class P47ComposioProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://composio.render.invalid/api/v3.1/")!
    nonisolated(unsafe) static var connected = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let account = { (id: String, toolkit: String, alias: String) -> [String: Any] in ["id": id, "toolkit": ["slug": toolkit], "alias": alias, "status": "ACTIVE", "is_disabled": false] }
        let body: [String: Any]
        if path.hasSuffix("connected_accounts") {
            body = ["items": [account("ca_work", "gmail", "Work Gmail")] + (Self.connected ? [account("ca_team", "slack", "Team Slack")] : [])]
        } else if path.hasSuffix("tool_router/session") { body = ["session_id": "trs_render"] }
        else if path.hasSuffix("/link") { body = ["redirect_url": "https://connect.composio.dev/link/render"] }
        else { body = ["items": []] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

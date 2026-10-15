import AppKit
import SwiftUI

/// P38 B shots of `--render-setup` (alone with `--only p38b`): Settings → Connected apps as production starts (server
/// sign-in not set up) and with apps connected, the connect-app card in a reply, its sheet, an app action's approval
/// card, and an agent's Overview and Activity with connected apps. Composio answers come from an in-process protocol, the
/// ChatGPT account from an in-memory Codex stand-in: no network, no Keychain, no Codex process, no browser.
@MainActor enum HeadlessP38BShots {
    static let names = ["p38b-settings-apps-not-set-up", "p38b-settings-apps-connected", "p38b-chat-connect-card", "p38b-connect-sheet",
                        "p38b-chat-app-action", "p38b-agent-overview-apps", "p38b-agent-activity-apps"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let cfo = Bot(name: "Cfo", title: "Budgets and invoices", backend: .hermes, hermesProfile: "cfo")
        jarvis.avatarName = .allCases[0]; cfo.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]
        store.bots = [jarvis, cfo]; store.selectedBot = jarvis
        let directory = store.fileURL.deletingLastPathComponent()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RenderComposioProtocol.self]
        let session = URLSession(configuration: configuration)
        let keys = MemoryKeyStore(), panel = NSSize(width: 760, height: 2020)

        // 1. Production today: no key, the SwarmHub service answers that sign-in is not set up.
        let fresh = ConnectedAppsStore(directory: directory.appending(path: "fresh"), keyStore: keys, session: session, apiURL: RenderComposioProtocol.base, provisioner: PreviewProvisioner())
        fresh.serviceNote = ConnectedAppsCopy.signInNotSetUp
        store.connectedApps = fresh
        let signedOut = ChatGPTConnection(makeClient: { PreviewCodexConnection(signedIn: false) }, openURL: { _ in false })
        write(names[0], await png(AnyView(pane(fresh, store: store, chatGPT: signedOut).frame(width: panel.width, height: 1260)), store, NSSize(width: panel.width, height: 1260)))

        // 2. Connected: the user's own key, three accounts, Jarvis may use the work Gmail, ChatGPT connected, signed in.
        keys.setKey("synthetic-render-key", for: ConnectedAppsStore.keyAccount)
        let apps = ConnectedAppsStore(directory: directory.appending(path: "connected"), keyStore: keys, session: session, apiURL: RenderComposioProtocol.base, provisioner: PreviewProvisioner())
        await apps.refresh()
        if let work = apps.accounts.first { apps.setAllowed(true, account: work, botID: jarvis.id) }
        store.connectedApps = apps
        store.reportsCenter.account = .signedIn(expires: .now.addingTimeInterval(29 * 86_400))
        let connected = ChatGPTConnection(makeClient: { PreviewCodexConnection(signedIn: true) }, openURL: { _ in false }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        connected.refresh()
        for _ in 0..<200 where !connected.isConnected { try? await Task.sleep(for: .milliseconds(5)) }
        write(names[1], await png(AnyView(pane(apps, store: store, chatGPT: connected).frame(width: panel.width, height: panel.height)), store, panel))

        // 3–4. The card in Cfo's reply and the sheet it opens.
        let now = Date.now
        let ask = ChatMessage(role: .user, content: "Find the unpaid invoices in my inbox", createdAt: now.addingTimeInterval(-60))
        let card = ChatMessage(role: .assistant, content: "I can look through your inbox once Gmail is connected for me.\n\n```connect-app\n{\"app\":\"gmail\",\"reason\":\"Connect Gmail so I can find unpaid invoices and draft reminders.\"}\n```",
                               createdAt: now.addingTimeInterval(-55), turnState: .finished)
        cfo.messages = [ask, card]
        let chat = VStack(alignment: .leading, spacing: 0) { MessageView(message: ask); MessageView(message: card); Spacer() }
            .padding(.top, 10).environment(\.connectAppBotID, cfo.id)
        write(names[2], await png(AnyView(chat.frame(width: 820, height: 420, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 420)))
        let request = AppConnectionRequest(toolkit: "gmail", reason: "Connect Gmail so I can find unpaid invoices and draft reminders.")
        write(names[3], await png(AnyView(ConnectAppSheet(request: request, botID: cfo.id, apps: apps).frame(width: 440, height: 320, alignment: .top).background(AppColor.panel)), store, NSSize(width: 440, height: 320)))

        // 5. Jarvis asks to use Gmail: the approval card (always asked) in its chat.
        let question = ChatMessage(role: .user, content: "What came in from the accountant today?", createdAt: now.addingTimeInterval(-30))
        let command = #"{"account":"ca_work","app":"gmail","arguments":{"query":"from:accountant newer_than:1d"},"tool":"GMAIL_FETCH_EMAILS"}"#
        let action = ApprovalRequest(id: UUID(), title: "Fetch emails", summary: "gmail · Work Gmail", draft: command, command: command, botID: jarvis.id,
                                     actionKind: "composio.GMAIL_FETCH_EMAILS", routeNote: "App actions always ask you.")
        store.approvals = [action]; apps.localApprovals[action.id] = .chat
        let working = ChatMessage(role: .assistant, content: "", createdAt: now.addingTimeInterval(-25), isStreaming: true, metadata: ["status": "Waiting for your approval"])
        let rows = VStack(alignment: .leading, spacing: 0) { MessageView(message: question); MessageView(message: working); ApprovalCard(request: action) { _ in }; Spacer() }.padding(.top, 10)
        write(names[4], await png(AnyView(rows.frame(width: 820, height: 460, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 460)))

        // 6–7. Jarvis's Overview (its app accounts) and Activity (its app actions).
        let started = now.addingTimeInterval(-3 * 3600)
        let receipts: [ToolExecutionReceipt] = [
            .init(id: UUID(), botID: jarvis.id, sessionID: "chat", tool: "GMAIL_FETCH_EMAILS", account: "Work Gmail", arguments: #"{"query":"is:unread label:invoices"}"#,
                  state: .succeeded, outputExcerpt: #"{"data":{"emails":[{"from":"accountant@example.com","subject":"October invoices"}]},"successful":true}"#, createdAt: started),
            .init(id: UUID(), botID: jarvis.id, sessionID: "chat", tool: "GMAIL_SEND_EMAIL", account: "Work Gmail", arguments: #"{"to":"accountant@example.com","subject":"Re: October invoices"}"#,
                  state: .declined, createdAt: started.addingTimeInterval(600)),
            .init(id: UUID(), botID: jarvis.id, sessionID: "chat", tool: "SLACK_SEND_MESSAGE", account: "Team Slack", arguments: ##"{"channel":"#finance","text":"Invoices are in."}"##,
                  state: .unknown, createdAt: started.addingTimeInterval(900))
        ]
        for receipt in receipts { try? apps.record(receipt) }
        store.approvals = []
        store.infoTab = .overview
        write(names[5], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 760)))
        store.infoTab = .activity
        write(names[6], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 760)))
    }

    private static func pane(_ apps: ConnectedAppsStore, store: AppStore, chatGPT: ChatGPTConnection) -> some View {
        Form { SettingsConnectedAppsPane(apps: apps, center: store.reportsCenter, chatGPT: chatGPT, checksOnAppear: false) }
            .formStyle(.grouped).background(AppColor.panel)
    }
}

/// Renders only: a provisioner that is never reached (no Connect is pressed in a render).
@MainActor private struct PreviewProvisioner: ComposioProvisioning {
    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential { throw ComposioProvisioningError.unavailable }
}

/// Renders only: a signed-in (or signed-out) ChatGPT account whose silent voice check succeeds.
@MainActor private final class PreviewCodexConnection: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    let signedIn: Bool
    init(signedIn: Bool) { self.signedIn = signedIn }
    func connect() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        switch method {
        case "account/read":
            return .object(["account": signedIn ? .object(["type": .string("chatgpt"), "planType": .string("plus"), "email": .string("konrad@example.com")]) : .null])
        case "thread/start": return .object(["thread": .object(["id": .string("render-thread")])])
        case "thread/realtime/start":
            onNotification?("thread/realtime/started", .object(["threadId": .string("render-thread")]))
            return .object([:])
        default: return .object([:])
        }
    }
    func close(stopping threadID: String?) { onNotification = nil; onClose = nil }
}

/// Renders only: synthetic Composio answers served in-process (three connected accounts, popular apps).
final class RenderComposioProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://composio.render.invalid/api/v3.1/")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        let account = { (id: String, toolkit: String, alias: String) -> [String: Any] in ["id": id, "toolkit": ["slug": toolkit], "alias": alias, "status": "ACTIVE", "is_disabled": false] }
        let body: [String: Any] = path.hasSuffix("connected_accounts")
            ? ["items": [account("ca_work", "gmail", "Work Gmail"), account("ca_home", "gmail", "Personal Gmail"), account("ca_team", "slack", "Team Slack")]]
            : ["items": []]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

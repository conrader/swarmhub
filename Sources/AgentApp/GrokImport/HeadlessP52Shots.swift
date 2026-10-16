import AppKit
import SwiftUI

/// P52 shots of `--render-setup` (alone with `--only p52`): a chat where a GitHub read ran on its own (one folded line,
/// then unfolded) and a Gmail send asks on its card with the new note; the rule line in the Connect apps sheet and in
/// Settings → Connected apps. All synthetic and in memory: no network (requests are refused), no Keychain, nothing saved.
@MainActor enum HeadlessP52Shots {
    static let names = ["p52-chat-read-and-write", "p52-chat-read-unfolded", "p52-connected-apps-rule", "p52-settings-rule"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let plainsay = Bot(name: "Plainsay", title: "Writes plainly", backend: .hermes, hermesProfile: "plainsay")
        store.bots = [plainsay]; store.selectedBot = plainsay
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [P52NoNetwork.self]
        let keys = MemoryKeyStore(); keys.setKey("synthetic-render-key", for: ConnectedAppsStore.keyAccount)
        let apps = ConnectedAppsStore(directory: store.fileURL.deletingLastPathComponent().appending(path: "p52-apps"), keyStore: keys,
                                      session: URLSession(configuration: configuration))
        store.connectedApps = apps

        // 1. The chat: a read that ran on its own (the folded line), the answer, then a send waiting on its card.
        let now = Date.now
        let marker = "[[SWARMHUB_APP_REQUEST_00000000-0000-4000-8000-000000000052]]"
        let request = marker + "\n{\"action\":\"execute\",\"tool\":\"GITHUB_GET_THE_AUTHENTICATED_USER\",\"account\":\"octo-konrad\",\"arguments\":{}}"
        let result = ConnectedAppsChat.resultPrefix + #"{"data":{"followers":12,"following":3,"login":"octo-konrad","public_repos":7},"successful":true}"#
        let question = ChatMessage(role: .user, content: "How many followers do I have on GitHub? Then email Ana the number.", createdAt: now.addingTimeInterval(-60))
        let read = ChatMessage(role: .system, content: request, createdAt: now.addingTimeInterval(-55),
                               metadata: [TechnicalKey.appRequest: request, TechnicalKey.appResult: result])
        let answer = ChatMessage(role: .assistant, content: "You have **12 followers** on GitHub. I've drafted the email to Ana; it waits for your approval.",
                                 createdAt: now.addingTimeInterval(-50), turnState: .finished)
        let scope = ComposioRunScope(client: apps.client, userID: "render", accounts: ["gmail": ["ca_mail_work"]], labels: ["ca_mail_work": "konrad@work.example"], revision: UUID())
        let arguments: ComposioValue = .object(["recipient_email": .string("ana@example.com"), "subject": .string("GitHub followers"), "body": .string("12 followers today.")])
        let texts = try? AppAccountChoice.approvalTexts(app: "gmail", account: "ca_mail_work", tool: "GMAIL_SEND_EMAIL", arguments: arguments, scope: scope)
        let send = ApprovalRequest(id: UUID(), title: "Send email", summary: "Gmail · konrad@work.example", draft: texts?.draft, command: texts?.command, botID: plainsay.id,
                                   actionKind: "composio.GMAIL_SEND_EMAIL", routeNote: ConnectedAppsCopy.approvalRule)
        store.approvals = [send]; apps.localApprovals[send.id] = .chat
        let fold = store.technicalLayout([read], botName: plainsay.name).folds[read.id]
        func chat(_ height: CGFloat) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 0) {
                MessageView(message: question); MessageView(message: read, fold: fold); MessageView(message: answer); ApprovalCard(request: send) { _ in }; Spacer()
            }.padding(.top, 10).frame(width: 820, height: height, alignment: .topLeading).background(AppColor.chat))
        }
        write(names[0], await png(chat(560), store, NSSize(width: 820, height: 560)))
        store.technicalFolds.unfold(TechnicalFolds.key(read.id))
        write(names[1], await png(chat(760), store, NSSize(width: 820, height: 760)))
        store.approvals = []

        // 2. The rule line: the Connect apps sheet's header, and Settings → Connected apps.
        write(names[2], await png(AnyView(ConnectAppsModal(apps: apps, checksOnAppear: false)), store, NSSize(width: 720, height: 680)))
        let chatGPT = ChatGPTConnection(makeClient: { P48SignedOutCodex() }, openURL: { _ in false })
        let pane = Form { SettingsConnectedAppsPane(apps: apps, chatGPT: chatGPT, checksOnAppear: false) }.formStyle(.grouped).background(AppColor.panel)
        write(names[3], await png(AnyView(pane.frame(width: 760, height: 900)), store, NSSize(width: 760, height: 900)))
    }
}

/// Renders only: every request fails at once, so nothing leaves the Mac.
private final class P52NoNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

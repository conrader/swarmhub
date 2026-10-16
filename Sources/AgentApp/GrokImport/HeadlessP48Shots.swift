import AppKit
import SwiftUI

/// P48 shots of `--render-setup` (alone with `--only p48`): the Connect apps sheet before any connection, after two
/// Gmails and a GitHub (names, Add another account, the bots using each, that popover open) and searching (a local
/// filter with catalog matches, and "No apps match"); Connected accounts with the named
/// accounts and Agent access with two Gmails on for Jarvis; the Rename sheet; a chat with an approval card naming the
/// account and an app error line with Composio's message. Composio answers come from an in-process protocol, logos from
/// a fake loader (GitHub's "fails", so its tile shows the letter): no network, no Keychain, no browser.
@MainActor enum HeadlessP48Shots {
    static let names = ["p48-modal-before-connecting", "p48-modal-connected", "p48-modal-search", "p48-settings-accounts",
                        "p48-rename-sheet", "p48-chat-approval-and-error", "p48-modal-usage-popover",
                        "p48-modal-search-no-match"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let cfo = Bot(name: "Cfo", title: "Budgets and invoices", backend: .hermes, hermesProfile: "cfo")
        let infra = Bot(name: "Infra", title: "Servers and deploys", backend: .hermes, hermesProfile: "infra")
        jarvis.avatarName = .allCases[0]; cfo.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]
        infra.avatarName = .allCases[min(5, BotAvatarName.allCases.count - 1)]
        store.bots = [jarvis, cfo, infra]; store.selectedBot = jarvis
        let directory = store.fileURL.deletingLastPathComponent()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [P48ComposioProtocol.self]
        let session = URLSession(configuration: configuration)
        let logos = P48FakeLogos()
        let modalSize = NSSize(width: 720, height: 680)

        // 1. Before any connection: no key yet (the first Connect gets one), the popular apps with their logos.
        let fresh = ConnectedAppsStore(directory: directory.appending(path: "p48-fresh"), keyStore: MemoryKeyStore(), session: session,
                                       apiURL: P48ComposioProtocol.base, provisioner: P48Provisioner())
        store.connectedApps = fresh
        write(names[0], await png(AnyView(ConnectAppsModal(apps: fresh, checksOnAppear: false).environment(\.appLogoLoader, logos)), store, modalSize))

        // 2. Two Gmails and a GitHub, named after who they are (the profile call ran on the first refresh). Both Gmails
        //    are on for Jarvis; the home one also for Infra, the work one for Cfo; GitHub for no bot.
        let keys = MemoryKeyStore(); keys.setKey("synthetic-render-key", for: ConnectedAppsStore.keyAccount)
        let apps = ConnectedAppsStore(directory: directory.appending(path: "p48-connected"), keyStore: keys, session: session, apiURL: P48ComposioProtocol.base)
        P48ComposioProtocol.reset()
        await apps.refresh(); await apps.search("")
        for account in apps.accounts where account.toolkit == "gmail" {
            apps.setAllowed(true, account: account, botID: jarvis.id)
            apps.setAllowed(true, account: account, botID: account.id == "ca_mail_home" ? infra.id : cfo.id)
        }
        store.connectedApps = apps
        write(names[1], await png(AnyView(ConnectAppsModal(apps: apps, checksOnAppear: false).environment(\.appLogoLoader, logos)), store, modalSize))

        // 2b. The same sheet with the work Gmail's "Used by" popover open (drawn in place: a popover is its own window).
        if let work = apps.accounts.first(where: { $0.id == "ca_mail_work" }) {
            let popover = AccountUsagePopover(account: work, bots: store.connectedAppsBots, apps: apps)
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5)).shadow(radius: 12, y: 4)
            let modal = ConnectAppsModal(apps: apps, checksOnAppear: false).environment(\.appLogoLoader, logos)
                .overlay(alignment: .topLeading) { popover.offset(x: 50, y: 368) }
            write(names[6], await png(AnyView(modal), store, modalSize))
        } else { write(names[6], nil) }

        // 3. Search: "cal" filters the tiles at once and, after the pause, adds the catalog's other matches below; "zzz"
        //    matches nothing. The pause is skipped here (no sleep), the catalog answer is the in-process one.
        for (index, term) in [(2, "cal"), (7, "zzz")] {
            let search = ConnectAppsSearch(wait: { _ in }, find: { [apps] in await apps.catalogMatches($0) })
            search.text = term; await search.settle()
            write(names[index], await png(AnyView(ConnectAppsModal(apps: apps, checksOnAppear: false, search: search).environment(\.appLogoLoader, logos)), store, modalSize))
        }

        // 4. Settings → Connected apps: the named accounts with Rename…, Agent access with both Gmails on for Jarvis.
        let chatGPT = ChatGPTConnection(makeClient: { P48SignedOutCodex() }, openURL: { _ in false })
        let panel = NSSize(width: 760, height: 1500)
        let pane = Form { SettingsConnectedAppsPane(apps: apps, chatGPT: chatGPT, checksOnAppear: false) }.formStyle(.grouped).background(AppColor.panel)
        write(names[3], await png(AnyView(pane.frame(width: panel.width, height: panel.height)), store, panel))

        // 5. Rename… on the work Gmail.
        if let work = apps.accounts.first(where: { $0.label == "konrad@work.example" }) {
            let sheet = RenameAccountSheet(apps: apps, account: work).background(AppColor.panel)
            write(names[4], await png(AnyView(sheet.frame(width: 400, height: 200)), store, NSSize(width: 400, height: 200)))
        } else { write(names[4], nil) }

        // 6. Jarvis's chat: an approval card that names the account, then a GitHub read Composio refused (its message shown).
        let now = Date.now
        let question = ChatMessage(role: .user, content: "Check my work inbox for the accountant, then tell me who I am on GitHub", createdAt: now.addingTimeInterval(-40))
        let scope = ComposioRunScope(client: apps.client, userID: "render", accounts: ["gmail": ["ca_mail_home", "ca_mail_work"]],
                                     labels: Dictionary(uniqueKeysWithValues: apps.accounts.map { ($0.id, $0.label) }), revision: UUID())
        let texts = try? AppAccountChoice.approvalTexts(app: "gmail", account: "ca_mail_work", tool: "GMAIL_FETCH_EMAILS",
                                                        arguments: .object(["query": .string("from:accountant newer_than:1d")]), scope: scope)
        let action = ApprovalRequest(id: UUID(), title: "Fetch emails", summary: "Gmail · konrad@work.example", draft: texts?.draft, command: texts?.command, botID: jarvis.id,
                                     actionKind: "composio.GMAIL_FETCH_EMAILS", routeNote: "App actions always ask you.")
        store.approvals = [action]; apps.localApprovals[action.id] = .chat
        let failure = ChatMessage(role: .system, content: "Jarvis: Get the authenticated user failed. Composio: Connected account ca_gh is not part of this session (ToolRouter_AccountNotInSession) Create a session that pins this account.",
                                  createdAt: now.addingTimeInterval(-30), metadata: [TurnKey.tone: "warning"])
        let answer = ChatMessage(role: .assistant, content: "GitHub refused the request, so I can't tell who you are there yet. Your work inbox check is waiting for your approval.",
                                 createdAt: now.addingTimeInterval(-28), turnState: .finished)
        let rows = VStack(alignment: .leading, spacing: 0) {
            MessageView(message: question); MessageView(message: failure); MessageView(message: answer); ApprovalCard(request: action) { _ in }; Spacer()
        }.padding(.top, 10)
        write(names[5], await png(AnyView(rows.frame(width: 820, height: 560, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 560)))
        store.approvals = []
    }
}

/// Renders only: logos drawn in memory. GitHub's load "fails", so its tile shows the letter fallback.
@MainActor private final class P48FakeLogos: AppLogoLoading {
    func image(for url: URL) async -> NSImage? {
        let slug = url.lastPathComponent
        guard slug != "github" else { return nil }
        let colors: [String: NSColor] = ["gmail": .systemRed, "googlecalendar": .systemBlue, "slack": .systemPurple, "googledrive": .systemGreen,
                                         "notion": .black, "outlook": .systemTeal, "calendly": .systemIndigo]
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        (colors[slug] ?? .systemOrange).setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 52, height: 52), xRadius: 14, yRadius: 14).fill()
        let glyph = NSAttributedString(string: String(slug.prefix(1)).uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .heavy), .foregroundColor: NSColor.white])
        glyph.draw(at: NSPoint(x: 32 - glyph.size().width / 2, y: 32 - glyph.size().height / 2))
        image.unlockFocus()
        return image
    }
}

@MainActor private struct P48Provisioner: ComposioProvisioning {
    func credentialForFirstConnection(toolkit: String) async throws -> ProvisionedComposioCredential { throw ComposioProvisioningError.unavailable }
}

/// Renders only: a ChatGPT account that is not signed in (no Codex process).
@MainActor final class P48SignedOutCodex: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        method == "account/read" ? .object(["account": .null]) : .object([:])
    }
    func close(stopping threadID: String?) { onNotification = nil; onClose = nil }
}

/// Renders only: synthetic Composio answers served in-process. Two Gmails and a GitHub without aliases; their profile
/// calls answer with an email or a login, and the alias PATCHes are kept.
final class P48ComposioProtocol: URLProtocol, @unchecked Sendable {
    static let base = URL(string: "https://composio.render.invalid/api/v3.1/")!
    nonisolated(unsafe) static var aliases: [String: String] = [:]
    nonisolated(unsafe) static var pinned = ""
    static func reset() { aliases = [:] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private static let catalog: [(String, String, String)] = [
        ("gmail", "Gmail", "Email and drafts"), ("github", "GitHub", "Repositories and issues"), ("slack", "Slack", "Channels and messages"),
        ("googlecalendar", "Google Calendar", "Events and calendars"), ("notion", "Notion", "Pages and databases"), ("googledrive", "Google Drive", "Files and documents"),
        ("outlook", "Outlook", "Mail, calendar and contacts"), ("calendly", "Calendly", "Scheduling links and bookings"),
    ]
    override func startLoading() {
        let path = request.url?.path ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" }?.value?.lowercased() ?? ""
        let body: [String: Any]
        let accounts: [(String, String, String)] = [("ca_mail_home", "gmail", "2026-10-02T09:00:00Z"), ("ca_mail_work", "gmail", "2026-10-16T04:40:00Z"), ("ca_gh", "github", "2026-10-16T04:43:00Z")]
        if path.hasSuffix("connected_accounts") {
            body = ["items": accounts.map { id, toolkit, created -> [String: Any] in
                ["id": id, "toolkit": ["slug": toolkit], "status": "ACTIVE", "is_disabled": false, "word_id": "\(toolkit)_red-castle", "created_at": created, "alias": Self.aliases[id] ?? NSNull()]
            }]
        } else if request.httpMethod == "PATCH", let id = path.split(separator: "/").last {
            Self.aliases[String(id)] = (Self.body(request)["alias"] as? String) ?? ""; body = ["id": String(id)]
        } else if path.hasSuffix("tool_router/session") {
            Self.pinned = ((Self.body(request)["connected_accounts"] as? [String: [String]])?.values.first?.first) ?? ""; body = ["session_id": "trs_render"]
        } else if path.hasSuffix("/execute") {
            let names = ["ca_mail_home": "konrad@example.com", "ca_mail_work": "konrad@work.example"]
            body = ["successful": true, "data": Self.pinned == "ca_gh" ? ["login": "conrader"] : ["emailAddress": names[Self.pinned] ?? "konrad@example.com"]]
        } else if path.hasSuffix("toolkits") {
            body = ["items": Self.catalog.filter { query.isEmpty || $0.1.lowercased().contains(query) || $0.2.lowercased().contains(query) }.map { slug, name, detail in
                ["slug": slug, "name": name, "meta": ["description": detail, "logo": "https://logos.composio.dev/api/\(slug)"]]
            }]
        } else { body = ["items": []] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

import AppKit
import SwiftUI

/// P40 shots of `--render-setup` (alone with `--only p40`): Settings → Connected apps with no sign-in anywhere: ready with
/// no apps, after the first connection (a real first Connect: this Mac's install registered, the project key provisioned
/// and stored, the Composio link made, not opened), not available (the service's `/health` 503), and a provisioning
/// error with Retry (429). SwarmHub and Composio answer from an in-process protocol: no network, no Keychain, no browser.
@MainActor enum HeadlessP40Shots {
    static let names = ["p40-apps-ready", "p40-apps-first-connection", "p40-apps-not-available", "p40-apps-retry"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        store.bots = [jarvis]; store.selectedBot = jarvis
        let directory = store.fileURL.deletingLastPathComponent().appending(path: "p40")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RenderP40Protocol.self]
        let session = URLSession(configuration: configuration)
        let signedOut = ChatGPTConnection(makeClient: { RenderNoCodex() }, openURL: { _ in false })
        let size = NSSize(width: 760, height: 1180), tall = NSSize(width: 760, height: 1500)

        func apps(_ name: String, status: Int = 200) -> (ConnectedAppsStore, MemoryKeyStore) {
            let keys = MemoryKeyStore(), center = ReportsCenter(fileURL: nil, keyStore: keys)
            center.session = session; center.openURL = { _ in }
            let service = SwarmHubService(baseURL: RenderP40Protocol.service(status), session: session)
            let provisioner = ComposioProvisioningClient(baseURL: RenderP40Protocol.service(status), session: session, credential: SwarmHubInstallIdentity(center: center, service: service))
            return (ConnectedAppsStore(directory: directory.appending(path: name), keyStore: keys, session: session, apiURL: RenderP40Protocol.composio, provisioner: provisioner), keys)
        }

        // 1. Ready: the service answers 200, no key yet, Connect enabled on every app.
        let (ready, _) = apps("ready"); store.connectedApps = ready
        write(names[0], await png(AnyView(pane(ready, chatGPT: signedOut).frame(width: size.width, height: size.height)), store, size))

        // 2. The first Connect: install registered, key provisioned and stored, the Gmail link made; then the account is back.
        let (first, keys) = apps("first"); store.connectedApps = first
        let link = await first.connect("gmail")
        await first.refresh()
        if let account = first.accounts.first { first.setAllowed(true, account: account, botID: jarvis.id) }
        if link == nil || !keys.hasKey(for: ConnectedAppsStore.keyAccount) { write(names[1], nil) }
        else { write(names[1], await png(AnyView(pane(first, chatGPT: signedOut).frame(width: tall.width, height: tall.height)), store, tall)) }

        // 3. Not available: `/health` 503.
        let (closed, _) = apps("closed"); closed.serviceNote = ConnectedAppsCopy.notAvailable; store.connectedApps = closed
        write(names[2], await png(AnyView(pane(closed, chatGPT: signedOut).frame(width: size.width, height: size.height)), store, size))

        // 4. The provisioning answered 429: the plain line and Retry.
        let (busy, _) = apps("busy", status: 429); store.connectedApps = busy
        _ = await busy.connect("gmail")
        write(names[3], await png(AnyView(pane(busy, chatGPT: signedOut).frame(width: size.width, height: size.height)), store, size))
    }

    private static func pane(_ apps: ConnectedAppsStore, chatGPT: ChatGPTConnection) -> some View {
        Form { SettingsConnectedAppsPane(apps: apps, chatGPT: chatGPT, checksOnAppear: false) }.formStyle(.grouped).background(AppColor.panel)
    }
}

/// Renders only: no ChatGPT account (the ChatGPT section is not what these shots are about).
@MainActor private final class RenderNoCodex: CodexVoiceConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onClose: (() -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        method == "account/read" ? .object(["account": .null]) : .object([:])
    }
    func close(stopping threadID: String?) {}
}

/// Renders only: SwarmHub (`/v1/installs`, `/v1/composio/provision`, answering `status` on provision) and Composio
/// (a session, its link, one connected Gmail account) served in-process.
final class RenderP40Protocol: URLProtocol, @unchecked Sendable {
    static let composio = URL(string: "https://composio.p40.render.invalid/api/v3.1/")!
    static func service(_ status: Int) -> URL { URL(string: "https://swarmhub-\(status).p40.render.invalid/swarmhub/")! }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        let provisionStatus = Int(url.host?.split(separator: ".").first?.split(separator: "-").last ?? "") ?? 200
        let (status, body): (Int, Any) = switch true {
        case path.hasSuffix("/v1/installs"): (201, ["install_id": "ins_render", "install_key": "render-install-key"])
        case path.hasSuffix("/v1/composio/provision"):
            provisionStatus == 200 ? (200, ["project_id": "pr_render", "api_key": "ak_render_project", "user_id": "swarmhub_render"]) : (provisionStatus, ["error": "synthetic"])
        case path.hasSuffix("tool_router/session"): (201, ["session_id": "trs_render"])
        case path.hasSuffix("/link"): (201, ["redirect_url": "https://connect.composio.dev/link/render"])
        case path.hasSuffix("connected_accounts"):
            (200, ["items": [["id": "ca_work", "toolkit": ["slug": "gmail"], "alias": "Work Gmail", "status": "ACTIVE", "is_disabled": false]]])
        default: (200, ["items": []])
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

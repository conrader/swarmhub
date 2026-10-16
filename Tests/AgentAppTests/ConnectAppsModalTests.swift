import AppKit
import Foundation
import Testing
@testable import AgentApp

/// P48 item 4: logos for the Connect apps sheet. Logo requests are answered in-process (`LogoProtocol`); no real logo
/// is ever loaded.
private final class LogoProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URL] = []
    static let lock = NSLock()
    static let png: Data = {
        let image = NSImage(size: NSSize(width: 4, height: 4)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.requests.append(url); Self.lock.unlock()
        let (status, type, body): (Int, String, Data) = url.path.hasSuffix("/gmail") ? (200, "image/png", Self.png)
            : url.path.hasSuffix("/html") ? (200, "text/html", Data("<html>".utf8)) : (404, "application/json", Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func logosLoadOnlyFromComposiosLogoHostOverHttpsAndAreCached() async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LogoProtocol.self]
    let loader = AppLogoLoader(session: URLSession(configuration: configuration))
    LogoProtocol.requests = []
    let gmail = URL(string: "https://logos.composio.dev/api/gmail")!
    #expect(await loader.image(for: gmail) != nil)
    #expect(await loader.image(for: gmail) != nil)
    #expect(await loader.image(for: URL(string: "https://logos.composio.dev/api/missing")!) == nil)
    #expect(await loader.image(for: URL(string: "https://logos.composio.dev/api/missing")!) == nil)
    #expect(await loader.image(for: URL(string: "https://logos.composio.dev/api/html")!) == nil, "not an image type")
    for refused in ["http://logos.composio.dev/api/gmail", "https://evil.test/api/gmail", "https://logos.composio.dev.evil.test/api/gmail",
                    "https://user:pw@logos.composio.dev/api/gmail", "https://logos.composio.dev:8443/api/gmail"] {
        #expect(await loader.image(for: URL(string: refused)!) == nil)
    }
    #expect(LogoProtocol.requests.map(\.lastPathComponent) == ["gmail", "missing", "html"], "cached once, failures not retried, refused hosts never asked")
}

@Test func toolkitsCarryTheirHttpsLogoAndPopularAppsUseThePublicLogoHost() throws {
    func toolkit(_ logo: String) -> ComposioToolkit? {
        ComposioToolkit(.object(["slug": .string("notion"), "name": .string("Notion"), "meta": .object(["description": .string("Pages"), "logo": .string(logo)])]))
    }
    #expect(toolkit("https://logos.composio.dev/api/notion")?.logo?.absoluteString == "https://logos.composio.dev/api/notion")
    #expect(toolkit("http://logos.composio.dev/api/notion")?.logo == nil && toolkit("javascript:alert(1)")?.logo == nil)
    #expect(ComposioToolkit.popular.allSatisfy { $0.logo.map(AppLogoLoader.allowed) == true && $0.logo?.lastPathComponent == $0.id })
}

@Test func theExplanationSaysOnlyWhatTheCodeDoes() {
    let text = ConnectedAppsCopy.composioExplanation
    for phrase in ["through Composio", "own page in your browser", "never sees your password", "waits for your approval in its chat",
                   "reads who it is once", "on for all your bots", "disconnect any account"] { #expect(text.contains(phrase)) }
    #expect(ConnectedAppsCopy.composioSite.absoluteString == "https://composio.dev")
}

@MainActor @Test func theModalsConnectIsOnForEveryBotAndNamedAfterWhoItIs() async throws {
    // The modal's Connect calls `connect(_:grantingTo:)` with every eligible bot (P47); the new account is then named (item 3).
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes), cfo = Bot(name: "Cfo", backend: .hermes)
    store.bots = [jarvis, cfo]
    final class Accounts: @unchecked Sendable { var connected = false }
    let state = Accounts()
    let (apps, _, _) = composioFixture { request in
        let path = request.url!.path
        if path.hasSuffix("connected_accounts") {
            let row: [String: Any] = ["id": "ca_new", "toolkit": ["slug": "gmail"], "status": "ACTIVE", "alias": NSNull()]
            return (200, ["items": state.connected ? [row] : []])
        }
        if path.hasSuffix("/execute") { return (200, ["successful": true, "data": ["emailAddress": "konrad@example.com"]]) }
        if request.httpMethod == "PATCH" { return (200, [:]) }
        return composioHandler(request)
    }
    #expect(await apps.connect("gmail", grantingTo: store.connectedAppsBots.map(\.id)) != nil)
    state.connected = true
    await apps.refresh()
    #expect(apps.grants(for: jarvis.id) == ["ca_new"] && apps.grants(for: cfo.id) == ["ca_new"])
    #expect(apps.accounts.first?.label == "konrad@example.com")
}

import Foundation
import Testing
@testable import AgentApp

// P36: PKCE, the desktop sign-in poller, report ops, the inbox state machine, the POST body, 429/401 handling, the quiet
// listing and close turns, and the Help menu's prefill. SwarmHub is `SwarmHubStub` (a URLProtocol on a `.test` host),
// the box is `ChatParityServer`; no network, no Keychain (InMemoryKeyStore).

final class SwarmHubStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, [String: Any]?) -> (Int, Any)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [(request: URLRequest, body: [String: Any]?)]] = [:]

    static func serve(_ handler: @escaping Handler) -> (service: SwarmHubService, host: String, session: URLSession) {
        let host = "swarmhub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SwarmHubStub.self]
        let session = URLSession(configuration: configuration)
        return (SwarmHubService(baseURL: URL(string: "https://\(host)/swarmhub")!, session: session), host, session)
    }
    static func requests(_ host: String) -> [(request: URLRequest, body: [String: Any]?)] { lock.withLock { log[host] ?? [] } }
    static func paths(_ host: String) -> [String] { requests(host).map { "\($0.request.httpMethod ?? "") \($0.request.url!.path)" } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(buffer, count: n) }
            stream.close(); data = bytes
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { Self.log[host, default: []].append((request, body)); return Self.handlers[host] }
        let (status, json) = handler?(request, body) ?? (404, ["error": "no route"])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// start → `authorization_url` with the server's state `srv-1`; status answers nil `pending` times, then `callback`.
private func signInServer(pending: Int = 2, callbackState: (@Sendable (String) -> String)? = nil, exchangeStatus: Int = 200,
                          appState: @escaping @Sendable () -> String) -> (SwarmHubService, String, URLSession) {
    let polls = LockedTrace()
    let (service, host, session) = SwarmHubStub.serve { request, body in
        switch request.url!.path {
        case "/swarmhub/v1/auth/start": return (200, ["authorization_url": "https://login.example.test/authorize?state=srv-1&x=1"])
        case "/swarmhub/v1/auth/status":
            polls.add("poll")
            guard polls.read().count > pending else { return (200, ["callback_url": NSNull()]) }
            let state = callbackState?(appState()) ?? appState()
            return (200, ["callback_url": "swarmhub://app-connections/sign-in?code=c-42&state=\(state)"])
        case "/swarmhub/v1/auth/exchange": return exchangeStatus == 200 ? (200, ["access_token": "tok-1", "expires_at": "2026-11-14T10:00:00Z"]) : (exchangeStatus, ["error": "no"])
        default: return (404, ["error": "no route"])
        }
    }
    return (service, host, session)
}

// MARK: PKCE and sign-in

@Test func pkceValuesFollowTheContract() {
    // Reference value from Python: base64.urlsafe_b64encode(hashlib.sha256(verifier).digest()).rstrip(b"=").
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r-wW1gFWFOEjXk") == "NPsYzawS-__wqk67X9gyb4dr3JBo3hnlEi5MNyD5jX0")
    let pkce = PKCE.make(), other = PKCE.make()
    #expect(PKCE.isURLSafe(pkce.verifier, length: 43...128) && PKCE.isURLSafe(pkce.state, length: 16...128))
    #expect(pkce.challenge.count == 43 && !pkce.challenge.contains("=") && PKCE.isURLSafe(pkce.challenge, length: 43...43))
    #expect(pkce.verifier != other.verifier && pkce.state != other.state)
}

@Test func signInPollsTheServerStateChecksTheAppStateAndExchanges() async throws {
    let pkce = PKCE.make()
    let (service, host, _) = signInServer(appState: { pkce.state })
    let opened = LockedTrace()
    let token = try await SwarmHubSignIn.run(service, pkce: pkce, open: { opened.add($0.absoluteString) }, sleep: { _ in })
    #expect(token.accessToken == "tok-1" && token.expiresAt == ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z"))
    #expect(opened.read() == ["https://login.example.test/authorize?state=srv-1&x=1"])
    let log = SwarmHubStub.requests(host)
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/auth/start"] + Array(repeating: "GET /swarmhub/v1/auth/status", count: 3) + ["POST /swarmhub/v1/auth/exchange"])
    #expect(log[0].body as? [String: String] == ["challenge": pkce.challenge, "state": pkce.state])
    #expect(log[1].request.url?.query == "state=srv-1", "polls the server's state, not the app's")
    #expect(log.last?.body as? [String: String] == ["code": "c-42", "verifier": pkce.verifier])
}

@Test func signInRefusesAnotherStateTimesOutAndReports401() async throws {
    let pkce = PKCE.make()
    let (mismatch, host, _) = signInServer(pending: 0, callbackState: { _ in "someone-else" }, appState: { pkce.state })
    await #expect(throws: SwarmHubError.stateMismatch) { try await SwarmHubSignIn.run(mismatch, pkce: pkce, open: { _ in }, sleep: { _ in }) }
    #expect(!SwarmHubStub.paths(host).contains("POST /swarmhub/v1/auth/exchange"))

    let (slow, slowHost, _) = signInServer(pending: 99, appState: { pkce.state })
    let slept = LockedTrace()
    await #expect(throws: SwarmHubError.timedOut) { try await SwarmHubSignIn.run(slow, pkce: pkce, maxPolls: 3, open: { _ in }, sleep: { slept.add("\($0)") }) }
    #expect(SwarmHubStub.paths(slowHost).filter { $0.hasSuffix("status") }.count == 3 && slept.read() == Array(repeating: "\(Duration.seconds(1))", count: 3))

    let (refused, _, session) = signInServer(pending: 0, exchangeStatus: 401, appState: { pkce.state })
    await #expect(throws: SwarmHubError.unauthorized) { try await SwarmHubSignIn.run(refused, pkce: pkce, open: { _ in }, sleep: { _ in }) }
    // Through the center the app's own PKCE is used; a 401 leaves "Sign in again" and no token.
    let center = await ReportsCenter(fileURL: nil, keyStore: InMemoryKeyStore())
    let ok = await MainActor.run { center.session = session; return center }.signIn(service: refused)
    #expect(!ok)
    await MainActor.run { #expect(center.account == .signedOut || center.account == .signInAgain); #expect(center.storedToken == nil) }
}

// MARK: Ops

@Test func reportOpsParse() {
    #expect(SwarmhubBlock.ops(in: "Filed.\n```swarmhub\n{\"op\":\"report\",\"id\":\"r20261015T101500Z-ab12cd34\",\"kind\":\"bug\",\"title\":\"bot-msg times out\"}\n```")
            == [.report(id: "r20261015T101500Z-ab12cd34", kind: .bug, title: "bot-msg times out")])
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n[{\"op\":\"report\",\"id\":\"../x\",\"kind\":\"bug\",\"title\":\"t\"},{\"op\":\"report\",\"id\":\"r1\",\"kind\":\"wish\",\"title\":\"t\"},{\"op\":\"report\",\"id\":\"r1\",\"kind\":\"feature\",\"title\":\" \"}]\n```") == [])
    let long = String(repeating: "x", count: 300)
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n{\"op\":\"report\",\"id\":\"r2\",\"kind\":\"feature\",\"title\":\"\(long)\"}\n```") == [.report(id: "r2", kind: .feature, title: String(long.prefix(140)))])
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n{\"op\":\"reports_closed\",\"sent\":[\"r1\",\"a b\"],\"deleted\":[\"r2\",3]}\n```") == [.reportsClosed(sent: ["r1"], deleted: ["r2"])])
}

@Test func theListingTurnCarriesBoxReports() throws {
    let line = #"{"op":"bots","list":[{"name":"cfo","has_key":true}],"reports":[{"id":"r1-aa","kind":"bug","title":"Hermes \"skills\" 500","body":"line1\nline2","source":"agent","bot":"cfo","bot_backend":"hermes","skill_versions":{"swarmhub-feedback":"1.0.0","bad name":"1.0.0","swarmhub-coding":"x"},"hermes_version":"0.22.0","created_at":"2026-10-15T10:15:00Z"},{"id":"r2","kind":"bug","title":"no body"}]}"#
    let ops = try #require(SwarmhubBlock.ops(in: "```swarmhub\n\(line)\n```"))
    #expect(ops.count == 2 && ops[0] == .bots([.init(name: "cfo", description: "", hasKey: true)]))
    guard case .boxReports(let rows) = ops[1] else { Issue.record("no reports op"); return }
    #expect(rows == [BoxReport(id: "r1-aa", kind: .bug, title: "Hermes \"skills\" 500", body: "line1\nline2", bot: "cfo", botBackend: "hermes",
                               skillVersions: ["swarmhub-feedback": "1.0.0"], hermesVersion: "0.22.0", createdAt: ISO8601DateFormatter().date(from: "2026-10-15T10:15:00Z"))])
    // A plain P35 list has no reports op.
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n{\"op\":\"bots\",\"list\":[]}\n```") == [.bots([])])
}

// MARK: Inbox state machine

@Test func inboxGoesPendingSentStatusAndDismiss() {
    var inbox = ReportsInbox(); let t0 = Date(timeIntervalSince1970: 1_000)
    inbox.absorbOp(id: "r1", kind: .bug, title: "t", bot: "cfo", connection: "box", now: t0)
    #expect(inbox.pendingCount == 1 && inbox.report("r1")?.hasBody == false && inbox.report("r1")?.boxFile == .present)
    inbox.absorbBox([BoxReport(id: "r1", kind: .bug, title: "Full title", body: "Body", skillVersions: ["swarmhub-feedback": "1.0.0"]),
                     BoxReport(id: "r2", kind: .feature, title: "Wish", body: "B2")], connection: "box", now: t0)
    #expect(inbox.report("r1")?.body == "Body" && inbox.report("r1")?.title == "Full title" && inbox.report("r1")?.skillVersions == ["swarmhub-feedback": "1.0.0"])
    inbox.edit("r1", title: "Edited", body: "Edited body")
    inbox.absorbBox([BoxReport(id: "r1", kind: .bug, title: "Full title", body: "Body")], connection: "box", now: t0)
    #expect(inbox.report("r1")?.title == "Edited" && inbox.report("r1")?.body == "Edited body", "Konrad's edits stay")
    inbox.markSent("r1", serverID: "17", status: "received", now: t0)
    #expect(inbox.report("r1")?.state == .sent && inbox.report("r1")?.boxFile == .markSent && inbox.pendingCount == 1)
    inbox.dismiss("r2")
    #expect(inbox.visible.map(\.id) == ["r1"] && inbox.boxWork(on: "box") == (["r1"], ["r2"]) && inbox.connectionsWithBoxWork == ["box"])
    inbox.boxClosed(sent: ["r1"], deleted: ["r2"])
    #expect(inbox.reports.map(\.id) == ["r1"] && inbox.report("r1")?.boxFile == .closed && inbox.boxWork(on: "box") == ([], []))
    inbox.applyStatuses([ServerReport(id: "17", status: "planned", note: "In 0.6"), ServerReport(id: "99", status: "done")])
    #expect(inbox.report("r1")?.status == "planned" && inbox.report("r1")?.note == "In 0.6")
    // A sent report's file listed again is closed again; a user report is dismissed at once.
    inbox.absorbBox([BoxReport(id: "r1", kind: .bug, title: "x", body: "y")], connection: "box", now: t0)
    #expect(inbox.report("r1")?.boxFile == .markSent && inbox.report("r1")?.title == "Edited")
    let mine = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: [], now: t0)
    inbox.add(mine); inbox.dismiss(mine.id)
    #expect(inbox.report(mine.id) == nil)
}

// MARK: POST body

@Test func postBodyShapeAndLimits() throws {
    var report = SwarmReport(id: "r1", source: .agent, kind: .feature, title: "  " + String(repeating: "t", count: 200), body: String(repeating: "b", count: 9_000),
                             bot: "cfo", connection: "box", botBackend: "hermes", hermesVersion: "0.22.0", createdAt: .now)
    report.skillVersions = Dictionary(uniqueKeysWithValues: (0..<25).map { (String(format: "skill-%02d", $0), "1.0.\($0)") })
    let payload = try #require(ReportPayload(report, appVersion: "0.5.0"))
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    #expect(Set(json.keys) == ["kind", "title", "body", "source", "bot", "bot_backend", "app_version", "skill_versions", "hermes_version"])
    #expect(json["kind"] as? String == "feature" && json["source"] as? String == "agent" && json["bot"] as? String == "cfo" && json["app_version"] as? String == "0.5.0")
    #expect((json["title"] as? String)?.count == 140 && (json["body"] as? String)?.count == 8000)
    let versions = try #require(json["skill_versions"] as? [String: String])
    #expect(versions.count == 20 && versions["skill-00"] == "1.0.0" && versions["skill-24"] == nil)
    // Konrad's own: no bot fields, empty optionals left out; an empty title is not sendable.
    var mine = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: ["Hermes"], now: .now); mine.title = "Crash"
    let userPayload = try #require(ReportPayload(mine, appVersion: "0.5.1"))
    let userJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(userPayload)) as? [String: Any])
    #expect(Set(userJSON.keys) == ["kind", "title", "body", "source", "app_version"] && userJSON["source"] as? String == "user" && userJSON["app_version"] as? String == "0.5.0")
    mine.title = "  "; #expect(ReportPayload(mine, appVersion: "0.5.0") == nil)
}

// MARK: Store: send, 429, 401, statuses

@MainActor private func reportsStore(token: Bool = true, _ handler: @escaping SwarmHubStub.Handler) -> (AppStore, String) {
    let keys = InMemoryKeyStore()
    if token { keys.setKey(#"{"accessToken":"tok-1","expiresAt":4102444800}"#, for: SwarmHubToken.account) }
    let (_, host, session) = SwarmHubStub.serve(handler)
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/swarmhub", forKey: SwarmHubService.baseURLKey)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: keys, defaults: defaults)
    store.reportsCenter.session = session; store.reportsCenter.sleep = { _ in }; store.reportsCenter.openURL = { _ in }
    return (store, host)
}

@Test @MainActor func sendPostsWithTheBearerAndStoresTheServerStatus() async throws {
    let (store, host) = reportsStore { request, _ in
        request.httpMethod == "POST" ? (201, ["id": 17, "status": "received"] as Any) : (200, [["id": "17", "kind": "bug", "title": "t", "status": "planned", "note": "In 0.6", "created_at": "2026-10-15T10:00:00Z", "updated_at": "2026-10-16T09:00:00Z"]] as Any)
    }
    #expect(store.reportsCenter.isSignedIn)
    var report = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: ["Hermes"], now: .now); report.title = "Crash on launch"
    store.reportsCenter.inbox.add(report)
    await store.sendReport(report.id)
    let sent = try #require(store.reportsCenter.inbox.report(report.id))
    #expect(sent.state == .sent && sent.serverID == "17" && sent.status == "received" && store.reportsCenter.lastError == nil)
    let post = try #require(SwarmHubStub.requests(host).first)
    #expect(post.request.url?.path == "/swarmhub/v1/reports" && post.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
    #expect(post.body?["title"] as? String == "Crash on launch" && post.body?["source"] as? String == "user")
    store.openReports()
    await store.refreshReportStatuses()
    #expect(store.reportsCenter.inbox.report(report.id)?.status == "planned" && store.reportsCenter.inbox.report(report.id)?.note == "In 0.6" && store.showingReports)
    // store.json never holds the token.
    store.save()
    let file = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!file.contains("tok-1"))
}

@Test @MainActor func rateLimitKeepsItPendingAnd401ForgetsTheTokenThenTriesTheInstallKey() async throws {
    let status = LockedTrace()
    let (store, _) = reportsStore { _, _ in status.read().isEmpty ? (429, ["error": "slow down"] as Any) : (401, ["error": "who"] as Any) }
    var report = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: [], now: .now); report.title = "t"
    store.reportsCenter.inbox.add(report)
    await store.sendReport(report.id)
    #expect(store.reportsCenter.inbox.report(report.id)?.state == .pending && store.reportsCenter.lastError == SwarmHubError.rateLimited.message)
    #expect(store.reportsCenter.isSignedIn)
    status.add("401")
    await store.sendReport(report.id)
    #expect(store.reportsCenter.account == .signInAgain && store.reportsCenter.storedToken == nil && store.keyStore.key(for: SwarmHubToken.account).isEmpty)
    // The fallback to an install key is refused too (here even its registration): still pending, one plain error.
    #expect(store.reportsCenter.inbox.report(report.id)?.state == .pending && store.reportsCenter.lastError?.contains("report key") == true)
    #expect(store.reportsCenter.storedInstall == nil)
}

@Test @MainActor func sendNeverSignsInAndSignOutForgetsTheToken() async throws {
    let (store, host) = reportsStore(token: false) { request, _ in
        request.url!.path == "/swarmhub/v1/installs" ? (201, ["install_id": "ins_1", "install_key": String(repeating: "k", count: 43)]) : (201, ["id": "rep_5", "status": "received"])
    }
    #expect(store.reportsCenter.account == .signedOut)
    var report = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: [], now: .now); report.title = "t"
    store.reportsCenter.inbox.add(report)
    await store.sendReport(report.id)
    #expect(store.reportsCenter.account == .signedOut && store.reportsCenter.inbox.report(report.id)?.serverID == "rep_5")
    #expect(!SwarmHubStub.paths(host).contains { $0.contains("/auth/") }, "Send never starts a sign-in")
    store.reportsCenter.store(SwarmHubToken(accessToken: "tok-new", expiresAt: .distantFuture))
    store.reportsCenter.forgetToken(signInAgain: false)
    #expect(store.reportsCenter.account == .signedOut && store.keyStore.key(for: SwarmHubToken.account).isEmpty && store.reportsCenter.storedInstall != nil)
}

// MARK: Help menu prefill

@Test @MainActor func helpMenuReportIsPrefilledWithoutSecrets() throws {
    let keys = InMemoryKeyStore(["hermes": "sk-live-secret-123456", "hermes.cfo": "derived-secret-abcdef"])
    let defaults = isolatedDefaults(); defaults.set("https://private-box.example.com/v1", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: keys, defaults: defaults)
    store.bots = [Bot(name: "Secret Agent Cfo", backend: .hermes, hermesProfile: "cfo"), Bot(name: "Atlas", isDemo: true)]
    let report = store.startUserReport()
    #expect(report.source == .user && report.title.isEmpty && store.showingReports && store.reportsCenter.selectedID == report.id)
    #expect(report.body.contains("SwarmHub \(store.appVersionText) · macOS \(ReportPrefill.macOSVersion()) · connections: Hermes"))
    for secret in ["sk-live", "derived-secret", "private-box", "Cfo", "cfo", "Atlas"] { #expect(!report.body.contains(secret), "\(secret)") }
    #expect(store.reportsCenter.inbox.pendingCount == 1, "nothing is sent without Send")
}

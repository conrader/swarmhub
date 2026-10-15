import Foundation
import Testing
@testable import AgentApp

// P36: reports with a per-install key (production has no sign-in): registration once and reuse, the Install header,
// Bearer when signed in, 401 → register again once, the `{"reports": [...]}` listing with epoch seconds, the 503
// sign-in message and `--check-reports` against `SwarmHubStub`. No network, no Keychain (InMemoryKeyStore).

private let installKey = String(repeating: "Ab3_-", count: 9).prefix(43).description

@MainActor private func installStore(token: Bool = false, _ handler: @escaping SwarmHubStub.Handler) -> (AppStore, String) {
    let keys = InMemoryKeyStore()
    if token { keys.setKey(#"{"accessToken":"tok-1","expiresAt":4102444800}"#, for: SwarmHubToken.account) }
    let (_, host, session) = SwarmHubStub.serve(handler)
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/swarmhub", forKey: SwarmHubService.baseURLKey)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() }, keyStore: keys, defaults: defaults)
    store.reportsCenter.session = session; store.reportsCenter.sleep = { _ in }; store.reportsCenter.openURL = { _ in }
    return (store, host)
}

@MainActor private func pendingReport(_ store: AppStore, title: String = "Crash on launch") -> String {
    var report = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: [], now: .now); report.title = title
    store.reportsCenter.inbox.add(report)
    return report.id
}

private func auth(_ host: String) -> [String] { SwarmHubStub.requests(host).map { $0.request.value(forHTTPHeaderField: "Authorization") ?? "-" } }

@Test @MainActor func installIsRegisteredOnceOnFirstSendAndReused() async throws {
    let ids = LockedTrace()
    let (store, host) = installStore { request, _ in
        if request.url!.path == "/swarmhub/v1/installs" { return (201, ["install_id": "ins_abc", "install_key": installKey]) }
        ids.add("x"); return (201, ["id": "rep_\(ids.read().count)", "status": "received"])
    }
    #expect(SwarmHubStub.paths(host).isEmpty && store.reportsCenter.storedInstall == nil, "nothing before the first Send")
    let first = pendingReport(store), second = pendingReport(store, title: "Second")
    await store.sendReport(first); await store.sendReport(second)
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/installs", "POST /swarmhub/v1/reports", "POST /swarmhub/v1/reports"])
    let register = try #require(SwarmHubStub.requests(host).first)
    #expect(register.body?.isEmpty == true && register.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(Array(auth(host).dropFirst()) == Array(repeating: "Install ins_abc.\(installKey)", count: 2))
    #expect(store.reportsCenter.inbox.report(first)?.serverID == "rep_1" && store.reportsCenter.inbox.report(second)?.serverID == "rep_2")
    #expect(store.reportsCenter.storedInstall == SwarmHubInstall(installID: "ins_abc", installKey: installKey) && store.reportsCenter.account == .signedOut)
    // The pair lives only in the key store.
    store.save()
    for file in [store.fileURL, store.fileURL.deletingLastPathComponent().appending(path: "reports.json")] {
        #expect(!((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(installKey), "\(file.lastPathComponent)")
    }
}

@Test @MainActor func bearerIsPreferredWhenSignedIn() async throws {
    let (store, host) = installStore(token: true) { _, _ in (201, ["id": "rep_7", "status": "received"]) }
    await store.sendReport(pendingReport(store))
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/reports"] && auth(host) == ["Bearer tok-1"])
    #expect(store.reportsCenter.storedInstall == nil, "no install is registered while signed in")
}

@Test @MainActor func unauthorizedInstallKeyRegistersAgainOnceAndRetriesOnce() async throws {
    let registrations = LockedTrace()
    let (store, host) = installStore { request, _ in
        if request.url!.path == "/swarmhub/v1/installs" {
            registrations.add("r"); return (201, ["install_id": "ins_\(registrations.read().count)", "install_key": installKey])
        }
        return request.value(forHTTPHeaderField: "Authorization")!.hasPrefix("Install ins_1.") ? (401, ["error": "unknown install"]) : (201, ["id": "rep_2", "status": "received"])
    }
    let id = pendingReport(store)
    await store.sendReport(id)
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/installs", "POST /swarmhub/v1/reports", "POST /swarmhub/v1/installs", "POST /swarmhub/v1/reports"])
    #expect(store.reportsCenter.inbox.report(id)?.serverID == "rep_2" && store.reportsCenter.storedInstall?.installID == "ins_2" && store.reportsCenter.lastError == nil)

    // Refused again after the new registration: no third try, the report stays pending.
    let (stubborn, stubbornHost) = installStore { request, _ in
        request.url!.path == "/swarmhub/v1/installs" ? (201, ["install_id": "ins_x", "install_key": installKey]) : (401, ["error": "no"])
    }
    let other = pendingReport(stubborn)
    await stubborn.sendReport(other)
    #expect(SwarmHubStub.paths(stubbornHost).count == 4 && stubborn.reportsCenter.inbox.report(other)?.state == .pending)
    #expect(stubborn.reportsCenter.lastError?.isEmpty == false)
}

@Test @MainActor func listingReadsTheReportsObjectWithEpochSeconds() async throws {
    let (store, host) = installStore { request, _ in
        let row: [String: Any] = ["id": "rep_abc", "kind": "bug", "title": "t", "status": "planned", "note": "In 0.6", "created_at": 1_760_000_000, "updated_at": 1_760_086_400]
        return switch (request.httpMethod!, request.url!.path) {
        case ("POST", "/swarmhub/v1/installs"): (201, ["install_id": "ins_abc", "install_key": installKey])
        case ("POST", _): (201, ["id": "rep_abc", "status": "received"])
        default: (200, ["reports": [row, ["id": "rep_other", "status": "received", "created_at": 1_760_000_001, "updated_at": 1_760_000_001]]])
        }
    }
    let rows = try await store.swarmHubService.listReports(auth: .install(SwarmHubInstall(installID: "ins_abc", installKey: installKey)))
    #expect(rows.map(\.id) == ["rep_abc", "rep_other"])
    #expect(rows[0] == ServerReport(id: "rep_abc", kind: "bug", title: "t", status: "planned", note: "In 0.6",
                                    createdAt: Date(timeIntervalSince1970: 1_760_000_000), updatedAt: Date(timeIntervalSince1970: 1_760_086_400)))
    let id = pendingReport(store)
    await store.sendReport(id)
    await store.refreshReportStatuses()
    let sent = try #require(store.reportsCenter.inbox.report(id))
    #expect(sent.status == "planned" && sent.note == "In 0.6" && sent.updatedAt == Date(timeIntervalSince1970: 1_760_086_400))
    #expect(SwarmHubStub.paths(host).last == "GET /swarmhub/v1/reports" && auth(host).last == "Install ins_abc.\(installKey)")
}

@Test @MainActor func refreshNeverRegistersAnInstall() async throws {
    let (store, host) = installStore { _, _ in (500, ["error": "unexpected"]) }
    var sent = ReportPrefill.make(appVersion: "0.5.0", macOS: "15.6", connectionKinds: [], now: .now); sent.state = .sent; sent.serverID = "rep_1"
    store.reportsCenter.inbox.add(sent)
    await store.refreshReportStatuses()
    #expect(SwarmHubStub.paths(host).isEmpty && store.reportsCenter.storedInstall == nil)
}

@Test @MainActor func signInNotConfiguredShowsOneMessageAndDoesNotPoll() async throws {
    let (store, host) = installStore { _, _ in (503, ["error": "sign-in is not configured"]) }
    let ok = await store.reportsCenter.signIn(service: store.swarmHubService)
    #expect(!ok && store.reportsCenter.account == .signedOut && store.reportsCenter.lastError == "SwarmHub sign-in isn't available yet.")
    #expect(SwarmHubError.signInUnavailable.message == "SwarmHub sign-in isn't available yet." && ReportsCopy.optional == "Optional — reports work without it.")
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/auth/start"])
}

// MARK: --check-reports

/// installs → `install`, POST reports → `send`, GET reports → `list` (statuses; `listed` false leaves the report out).
private func checkServer(install: Int = 201, send: Int = 201, list: Int = 200, listed: Bool = true) -> SwarmHubService {
    SwarmHubStub.serve { request, _ in
        switch (request.httpMethod!, request.url!.path) {
        case ("POST", "/swarmhub/v1/installs"): install == 201 ? (201, ["install_id": "ins_chk", "install_key": installKey]) : (install, ["error": "no"])
        case ("POST", "/swarmhub/v1/reports"): send == 201 ? (201, ["id": "rep_9", "status": "received"]) : (send, ["error": "no"])
        default:
            list == 200 ? (200, ["reports": listed ? [["id": "rep_9", "kind": "bug", "title": "x", "status": "received", "created_at": 1_760_000_000, "updated_at": 1_760_000_000]] : []]) : (list, ["error": "no"])
        }
    }.service
}

@Test @MainActor func checkReportsRegistersSendsAndLists() async throws {
    let service = checkServer(), host = service.baseURL.host!
    var lines: [String] = []
    let code = await HeadlessCheckReports.check(service: service, appVersion: "9.9.9") { lines.append($0) }
    #expect(code == 0 && lines == ["REPORTS: install ok | sent rep_9 | listed yes | status received"])
    #expect(SwarmHubStub.paths(host) == ["POST /swarmhub/v1/installs", "POST /swarmhub/v1/reports", "GET /swarmhub/v1/reports"])
    let body = try #require(SwarmHubStub.requests(host)[1].body)
    #expect(body as NSDictionary == ["kind": "bug", "title": "Self-test from the release check (ignore)", "body": "Automated end-to-end check of SwarmHub reports.",
                                      "source": "user", "app_version": "9.9.9"] as NSDictionary)
    #expect(Array(auth(host).dropFirst()) == Array(repeating: "Install ins_chk.\(installKey)", count: 2))
    #expect(lines.allSatisfy { !$0.contains(installKey) })
    #expect(HeadlessCommands.flags.contains("--check-reports") && HeadlessCommands.headless.contains("--check-reports"))
}

@Test @MainActor func checkReportsNamesTheFailingStep() async throws {
    let cases: [(SwarmHubService, String)] = [
        (checkServer(install: 503), "REPORTS: install failed | " + SwarmHubError.badResponse(503).message),
        (checkServer(install: 429), "REPORTS: install failed | " + SwarmHubError.rateLimited.message),
        (checkServer(send: 429), "REPORTS: send failed | " + SwarmHubError.rateLimited.message),
        (checkServer(list: 500), "REPORTS: list failed | " + SwarmHubError.badResponse(500).message)
    ]
    for (service, expected) in cases {
        var lines: [String] = []
        let code = await HeadlessCheckReports.check(service: service, appVersion: "9.9.9") { lines.append($0) }
        #expect(code == 1 && lines == [expected], "\(expected)")
    }
    var lines: [String] = []
    let code = await HeadlessCheckReports.check(service: checkServer(listed: false), appVersion: "9.9.9") { lines.append($0) }
    #expect(code == 1 && lines == ["REPORTS: install ok | sent rep_9 | listed no | status received", "REPORTS: list failed | rep_9 is not in the list"])
    #expect(HeadlessCommands.runIfRequested(arguments: ["AgentApp", "--check-reports", "ftp://nope"]) == 64)
}

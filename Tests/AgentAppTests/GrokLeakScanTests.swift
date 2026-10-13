import Foundation
import Testing
@testable import AgentApp

// P10b leak scan: drive the client and the fetcher with a synthetic token and machine id through every failure the
// fake can produce and assert neither secret appears in any error text, request URL or body, report, or any header
// other than the two that must carry them on RPCs (Authorization, x-cursor-checksum). Never contacts Grok.

private let alpha = "00000000-0000-4000-8000-0000000000a1"
private let secrets = [GrokFixtureSecrets.token, GrokFixtureSecrets.machineID]

private func fixture() -> FakeGrok {
    let fake = FakeGrok()
    fake.history = [alpha: Dictionary(uniqueKeysWithValues: (1...40).map { (Int64($0), FakeGrok.entry(Int64($0))) })]
    fake.blobSeqs = [30, 31]
    fake.omittedSeqs = [20]
    fake.goneBlobs = ["\(alpha)-s31"]
    fake.pageCap = 15
    return fake
}

private let failureReplies: [GrokStubProtocol.Reply] = [
    .http(400, Array(#"{"code":"invalid_argument","message":"echo Bearer x"}"#.utf8)), .http(401, []), .http(403, []), .http(404, []),
    .http(429, []), .http(500, []), .http(503, []), .fail(.networkConnectionLost), .fail(.secureConnectionFailed),
    .http(200, [0x08, 0x80]), .http(200, [0x0b]), .http(200, [0x0a, 0x05, 0x01]),
    .http(404, Array(#"{"code":"unimplemented"}"#.utf8)),
]

private func texts(of error: any Error) -> [String] {
    [String(describing: error), error.localizedDescription, String(reflecting: error), "\(error)"]
}

private func assertNoSecrets(_ text: String, _ label: String) {
    for secret in secrets { #expect(!text.contains(secret), "secret in \(label)") }
    #expect(!text.contains("Bearer "), "Bearer in \(label)")
}

@Test func leakScanOverEveryFailureOfTheClientAndFetcher() async {
    var scenarios: [FakeGrok] = []
    var reports: [String] = []
    var errors: [any Error] = []
    // Every failure reply, injected at each position of a fetch (list, presign, blob GET, omitted refetch, later pages).
    for reply in failureReplies {
        for position in [0, 1, 2, 3, 5] {
            let fake = fixture()
            fake.intercept = { index, _ in index == position ? reply : nil }
            var fetcher = GrokHistoryFetcher(client: fake.client())
            fetcher.pageLimit = 15
            let result = await fetcher.fetchOlder(agentID: alpha, beforeSeq: nil)
            if case .failed(let error)? = result.stop { errors.append(error) }
            reports.append(String(describing: result.stats) + String(describing: result.stop as Any))
            reports.append(String(describing: GrokHistoryMerge.merge(cached: [], fetched: result).coverage))
            scenarios.append(fake)
        }
    }
    // Redirects, rejected blob URLs, oversize bodies, the ceilings, cancellation and the ignored cursor.
    let redirect = fixture()
    redirect.intercept = { _, _ in .redirect(307, to: URL(string: "https://elsewhere-\(UUID().uuidString.lowercased()).test/")!) }
    let rejected = fixture()
    rejected.blobURLOverride = { _ in "https://127.0.0.1/\(GrokFixtureSecrets.token)" }
    let ignored = fixture()
    ignored.ignoresCursor = true
    for fake in [redirect, rejected, ignored] {
        let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: nil)
        if case .failed(let error)? = result.stop { errors.append(error) }
        reports.append(String(describing: result))
        scenarios.append(fake)
    }
    var small = GrokRPCClient.Limits()
    small.rpcMaxBytes = 32
    small.maxRequests = 2
    let tight = fixture()
    let tightClient = tight.client(limits: small)
    for _ in 0..<3 {
        do { _ = try await tightClient.listEntries(agentID: alpha, limit: 15, beforeSeq: nil) } catch { errors.append(error) }
    }
    scenarios.append(tight)
    let cancelled = await Task {
        await GrokHistoryFetcher(client: fixture().client()).fetchOlder(agentID: alpha, beforeSeq: nil) { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }.value
    reports.append(String(describing: cancelled))

    #expect(errors.count >= 30)
    #expect(Set(errors.compactMap { ($0 as? GrokServerError)?.reason }).count >= 8)
    for error in errors { for text in texts(of: error) { assertNoSecrets(text, "error \(text)") } }
    for report in reports { assertNoSecrets(report, "report") }

    for fake in scenarios {
        for request in fake.requests {
            assertNoSecrets(request.url, "URL")
            let body = String(decoding: request.body, as: UTF8.self)
            assertNoSecrets(body, "body")
            for (name, value) in request.headers {
                let allowed = request.method == "POST" && (name == "authorization" || name == "x-cursor-checksum")
                if !allowed { assertNoSecrets(value, "header \(name)") }
            }
            if request.method == "POST" {
                #expect(request.headers["authorization"] == "Bearer \(GrokFixtureSecrets.token)")
                #expect(request.headers["x-cursor-checksum"]?.hasSuffix(GrokFixtureSecrets.machineID) == true)
            } else {
                #expect(request.headers["authorization"] == nil && request.headers["x-cursor-checksum"] == nil)
            }
        }
    }
}

@Test func credentialsAndErrorsNeverPrintTheirSecrets() {
    let credentials = GrokFixtureSecrets.credentials
    for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials.token)", "\(credentials.machineID)"] {
        assertNoSecrets(text, "credentials")
    }
    let error = GrokServerError(.rejected, kind: .list, httpStatus: 400, connectCode: GrokFixtureSecrets.token, errorType: "URLError")
    #expect(error.connectCode == nil)
    for text in texts(of: error) { assertNoSecrets(text, "error") }
}

import Foundation
import Testing
@testable import AgentApp

// P10b: the RPC client against a URLProtocol FakeGrok. Never contacts Grok.

private let agent = "00000000-0000-4000-8000-0000000000a1"

private func smallFake() -> FakeGrok {
    let fake = FakeGrok()
    fake.history = [agent: Dictionary(uniqueKeysWithValues: (1...10).map { (Int64($0), FakeGrok.entry(Int64($0))) })]
    return fake
}

private func serverError(_ work: () async throws -> Void) async -> GrokServerError? {
    do { try await work(); return nil } catch let error as GrokServerError { return error } catch { return nil }
}

@Test func rpcHeadersIdentifyTorvliAndKeepTheProtocolHeaders() async throws {
    let fake = smallFake()
    let client = fake.client()
    _ = try await client.listEntries(agentID: agent, limit: 2, beforeSeq: nil)
    _ = try await client.listEntries(agentID: agent, limit: 2, beforeSeq: 5)
    let posts = fake.requests.filter { $0.method == "POST" }
    #expect(posts.count == 2)
    let h = posts[0].headers
    #expect(h["user-agent"] == "Torvli/1.4.0")
    #expect(h["x-cursor-client-version"] == "0.70.2")
    #expect(h["authorization"] == "Bearer \(GrokFixtureSecrets.token)")
    #expect(h["content-type"] == "application/proto")
    #expect(h["connect-protocol-version"] == "1")
    #expect(h["connect-timeout-ms"] == "15000")
    #expect(h["x-cursor-client-type"] == "sand")
    #expect(h["x-sand-box-namespace"] == "prod")
    #expect(h["x-cursor-client-os"] == "darwin")
    #expect(h["x-cursor-client-source"] == "sand-desktop")
    #expect(h["x-ghost-mode"] == "true")
    #expect(h["x-cursor-team-id"] == "42")
    #expect(h["x-cursor-checksum"]?.hasSuffix(GrokFixtureSecrets.machineID) == true)
    #expect(h["cookie"] == nil)
    // The checksum is recomputed and the request id renewed per request.
    #expect(posts[0].headers["x-cursor-checksum"] != posts[1].headers["x-cursor-checksum"])
    #expect(posts[0].headers["x-request-id"] != posts[1].headers["x-request-id"])
    #expect(posts[0].body == GrokProtobuf.encodeListRequest(agentID: agent, limit: 2))
    #expect(posts[1].body == GrokProtobuf.encodeListRequest(agentID: agent, limit: 2, beforeSeq: 5))
    #expect(posts.allSatisfy { $0.url.hasSuffix("/aiserver.v1.GrokBotService/ListGrokBotTranscriptEntries") })
}

@Test func userAgentDriftIsRecordedAndVersionsAreSanitised() throws {
    #expect(GrokProtocol.userAgent(appVersion: "1.2.3") == "Torvli/1.2.3")
    #expect(GrokRequestHeaders.appVersion(fromShortVersion: "1.2.3") == "1.2.3")
    #expect(GrokRequestHeaders.appVersion(fromShortVersion: "development build") == "dev")
    #expect(GrokRequestHeaders.appVersion(fromShortVersion: nil) == "dev")
    #expect(GrokRequestHeaders.appVersion(fromShortVersion: "1.2\r\nx: y") == "dev")
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Sources/AgentApp/GrokExport/GrokProtocol.swift").standardizedFileURL, encoding: .utf8)
    #expect(source.contains("Drift: changed 2026-10-13, Konrad approved."))
    #expect(!GrokRequestHeaders.rpcHeaders(token: "t", machineID: "", teamID: nil, clientVersion: "0.70.2", appVersion: "1.0",
                                           nowMs: 0).contains { $0.0 == "user-agent" && $0.1.contains("Sand/") })
}

@Test func pacingSpacesEveryRequestStart() async throws {
    let fake = smallFake(), clock = GrokFakeClock()
    fake.intercept = { _, _ in clock.advance(.milliseconds(100)); return nil }
    let client = fake.client(clock: clock)
    for _ in 0..<4 { _ = try await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
    #expect(clock.sleeps == [.milliseconds(400), .milliseconds(400), .milliseconds(400)])
    #expect(await client.requestCount == 4)
}

@Test func pacerReservesTheSlotBeforeSuspending() {
    var pacer = GrokPacer(interval: .milliseconds(500), maxRequests: 3)
    // Three callers arrive at the same instant: each gets its own slot, none shares one.
    #expect(pacer.reserve(now: .zero) == .zero)
    #expect(pacer.reserve(now: .zero) == .milliseconds(500))
    #expect(pacer.reserve(now: .zero) == .seconds(1))
    #expect(pacer.reserve(now: .seconds(5)) == nil)
}

@Test func serviceUnavailableIsRetriedThenSucceeds() async throws {
    let fake = smallFake(), clock = GrokFakeClock()
    fake.intercept = { index, _ in index == 0 ? .http(503, []) : nil }
    let rows = try await fake.client(clock: clock).listEntries(agentID: agent, limit: 3, beforeSeq: nil)
    #expect(rows.map(\.seq) == [10, 9, 8])
    #expect(fake.requests.count == 2)
    #expect(clock.sleeps == [.seconds(1)])
}

@Test func retriesStopAfterThreeWithBackoffOneTwoFour() async {
    for reply in [GrokStubProtocol.Reply.http(502, []), .http(504, []), .fail(.networkConnectionLost), .fail(.timedOut)] {
        let fake = smallFake(), clock = GrokFakeClock()
        fake.intercept = { _, _ in reply }
        let error = await serverError { _ = try await fake.client(clock: clock).listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
        #expect(error?.reason == .unavailable || error?.reason == .network)
        #expect(error?.pausesRun == true)
        #expect(fake.requests.count == 4)
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4)])
    }
}

@Test func clientErrorsAreNeverRetried() async {
    let expected: [(Int, GrokServerError.Reason)] = [(400, .rejected), (401, .signInInvalid), (403, .rejected), (404, .rejected),
                                                     (429, .rejected), (500, .rejected)]
    for (status, reason) in expected {
        let fake = smallFake(), clock = GrokFakeClock()
        fake.intercept = { _, _ in .http(status, Array(#"{"code":"resource_exhausted","message":"synthetic"}"#.utf8)) }
        let error = await serverError { _ = try await fake.client(clock: clock).listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
        #expect(error?.reason == reason, "HTTP \(status)")
        #expect(error?.httpStatus == status)
        #expect(fake.requests.count == 1, "HTTP \(status) was retried")
        #expect(clock.sleeps.isEmpty)
    }
    // A non-retryable network error is not retried either.
    let fake = smallFake()
    fake.intercept = { _, _ in .fail(.secureConnectionFailed) }
    let error = await serverError { _ = try await fake.client().listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
    #expect(error?.reason == .network)
    #expect(fake.requests.count == 1)
}

@Test func connectNotFoundOrUnimplementedMeansProtocolChanged() async {
    for code in ["not_found", "unimplemented"] {
        let fake = smallFake()
        fake.intercept = { _, _ in .http(404, Array(#"{"code":"\#(code)"}"#.utf8)) }
        let error = await serverError { _ = try await fake.client().listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
        #expect(error == GrokServerError(.protocolChanged, kind: .list, httpStatus: 404, connectCode: code))
    }
    #expect(GrokServerError.connectCode(fromBody: Array(#"{"code":"Bearer abc.def"}"#.utf8)) == nil)
}

@Test func redirectYieldsOneRequestAndNothingAtTheSecondOrigin() async {
    let fake = smallFake()
    let other = "other-\(UUID().uuidString.lowercased()).test"
    GrokStubProtocol.register(host: other) { _ in .http(200, []) }
    fake.intercept = { _, _ in .redirect(302, to: URL(string: "https://\(other)/steal")!) }
    let error = await serverError { _ = try await fake.client().listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
    #expect(error?.reason == .redirectRefused)
    #expect(error?.httpStatus == 302)
    #expect(fake.requests.count == 1)
    #expect(GrokStubProtocol.recorded(hosts: [other]).isEmpty)
}

@Test func blobURLsMustBeHTTPSAtAPublicHostName() async {
    for bad in ["http://blobs.example.test/x", "https://localhost/x", "https://LOCALHOST./x", "https://a.localhost/x",
                "https://printer.local/x", "https://127.0.0.1/x", "https://10.0.0.8/x", "https://192.168.1.2/x",
                "https://[::1]/x", "https://[fe80::1]/x", "https://2130706433/x", "https://0x7f.0x1/x", "https://user:pw@blobs.test/x",
                "ftp://blobs.test/x", "not a url", ""] {
        #expect(GrokBlobURL.validated(bad) == nil, "\(bad)")
    }
    #expect(GrokBlobURL.validated("https://blobs.example.test/blob/abc?X-Sig=1") != nil)
    let fake = smallFake()
    let error = await serverError { _ = try await fake.client().fetchBlob("https://127.0.0.1/blob/x") }
    #expect(error == GrokServerError(.blobURLRejected, kind: .blob))
    #expect(fake.requests.isEmpty)
}

@Test func blobGetsCarryNoAuthAndGoneBlobsAreNil() async throws {
    let fake = smallFake()
    fake.goneBlobs = ["\(agent)-s3"]
    let client = fake.client()
    let body = try await client.fetchBlob("https://\(fake.blobHost)/blob/\(agent)-s2")
    #expect(body.flatMap { try? GrokJSON.parse(Data($0)) }?["seq"] == .int(2))
    #expect(try await client.fetchBlob("https://\(fake.blobHost)/blob/\(agent)-s3") == nil)
    for get in fake.requests {
        #expect(get.method == "GET")
        #expect(get.headers.keys.allSatisfy { !$0.hasPrefix("x-") && $0 != "authorization" && $0 != "cookie" })
    }
}

@Test func oversizeBodiesAreRefused() async {
    let fake = smallFake()
    var limits = GrokRPCClient.Limits()
    limits.rpcMaxBytes = 64
    limits.blobMaxBytes = 8
    let client = fake.client(limits: limits)
    let rpc = await serverError { _ = try await client.listEntries(agentID: agent, limit: 5, beforeSeq: nil) }
    #expect(rpc?.reason == .tooLarge)
    let blob = await serverError { _ = try await client.fetchBlob("https://\(fake.blobHost)/blob/\(agent)-s2") }
    #expect(blob?.reason == .tooLarge)
    #expect(blob?.kind == .blob)
}

@Test func undecodableResponsesMeanProtocolChanged() async {
    let bodies: [[UInt8]] = [[0x08, 0x80], [0x0b], [0x0a, 0x05, 0x01], [0x0a, 0x02, 0x08, 0xff]]
    for body in bodies {
        let fake = smallFake()
        fake.intercept = { _, _ in .http(200, body) }
        let error = await serverError { _ = try await fake.client().listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
        #expect(error?.reason == .protocolChanged, "\(body)")
        #expect(error?.errorType == "GrokProtobufError")
        #expect(fake.requests.count == 1)
    }
    let fake = smallFake()
    fake.intercept = { _, _ in .http(200, [0x0b]) }
    let presign = await serverError { _ = try await fake.client().presign(relPaths: ["blobs/x"]) }
    #expect(presign == GrokServerError(.protocolChanged, kind: .presign, errorType: "GrokProtobufError"))
}

@Test func requestCeilingStopsTheRun() async {
    let fake = smallFake()
    var limits = GrokRPCClient.Limits()
    limits.maxRequests = 2
    let client = fake.client(limits: limits)
    _ = try? await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil)
    _ = try? await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil)
    let error = await serverError { _ = try await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil) }
    #expect(error?.reason == .requestCeiling)
    #expect(fake.requests.count == 2)
    #expect(GrokProtocol.maxRequestsPerRun == 2000 && GrokProtocol.maxPagesPerBot == 400)
}

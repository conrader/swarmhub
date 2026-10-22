#if DEBUG
import Foundation
import Testing
@testable import AgentApp

private func qaProof(nonce: String = "QA-nonce", now: Date = Date()) -> ComposioValue {
    var fields: [String: ComposioValue] = [:]
    for key in ["debug_build", "test_mode", "real_app", "real_hermes", "isolated_qa_store", "inventory_complete",
                "sandbox_enforced_app", "sandbox_enforced_hermes", "default_deny_tools", "egress_denied_except_model",
                "qa_peers_only", "qa_marker_propagated", "watchdog_active"] { fields[key] = .bool(true) }
    fields.merge(["schema": .string(QAPolicy.schema), "nonce": .string(nonce), "real_connector_count": .number(0),
        "production_jobs_accessible": .bool(false), "build": .string("unit-only"), "commit": .string("unit-only"),
        "hermes_version": .string("not-connected"), "sandbox_policy_digest": .string("unit-only"), "lease": .string("QA-unit-lease"),
        "expires_at": .number(now.timeIntervalSince1970 + 30), "capabilities": .strings(["chat.send", "observe", "cleanup"]),
        "connectors": .array(["email", "slack", "whatsapp", "connected-apps", "terminal", "browser", "http", "coding", "peers", "background"].map {
            .object(["name": .string($0), "implementation": .string("record-only"), "has_credentials": .bool(false), "network_enabled": .bool(false)])
        })], uniquingKeysWith: { _, new in new })
    return .object(fields)
}
private func qaDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-QA-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

@Test func qaNamesAndCommandsAreClosed() throws {
    #expect(QAPolicy.name("QA-unit-F03 [QA-TEST]"))
    for value in ["Real chat", "QA-no-marker", "QA-unit [QA-TEST]\n", "QA-../real [QA-TEST]", "QA-unit [QA-TEST] extra"] { #expect(!QAPolicy.name(value)) }
    for step: ComposioValue in [
        .object(["op": .string("shell")]), .object(["op": .string("chat.send"), "prompt": .string("secrets")]),
        .object(["op": .string("chat.send"), "prompt": .string("marker"), "url": .string("https://example.com")]),
        .object(["op": .string("routine.delete"), "prompt": .string("marker")]),
        .object(["op": .string("approval.decide"), "value": .string("approve-all")]),
        .object(["op": .string("approval.decide")])
    ] { #expect(throws: QAError.self) { try QAPolicy.step(step) } }
    #expect(try QAPolicy.text(.object(["op": .string("chat.send"), "prompt": .string("marker")]), resource: "QA-unit-F03 [QA-TEST]") == "[QA-TEST] QA-unit-F03 [QA-TEST] Reply with exactly the supplied QA marker. Do not use tools.")
}

@Test func qaSafetyRequiresEveryTypedFieldAndCompleteInventory() throws {
    let proof = qaProof(); try QAPolicy.attestation(proof, nonce: "QA-nonce")
    for key in proof.object!.keys {
        var fields = proof.object!; fields[key] = nil
        #expect(throws: QAError.self) { try QAPolicy.attestation(.object(fields), nonce: "QA-nonce") }
    }
    for (key, unsafe): (String, ComposioValue) in [("test_mode", .number(1)), ("real_connector_count", .bool(false)),
        ("expires_at", .number(Date().timeIntervalSince1970 - 1)), ("expires_at", .number(Date().timeIntervalSince1970 + 100)),
        ("sandbox_enforced_hermes", .bool(false)), ("watchdog_active", .bool(false)), ("production_jobs_accessible", .bool(true))] {
        var fields = proof.object!; fields[key] = unsafe
        #expect(throws: QAError.self) { try QAPolicy.attestation(.object(fields), nonce: "QA-nonce") }
    }
    for unsafe: ComposioValue in [.array([]), .array([.object(["name": .string("email"), "implementation": .string("record-only"), "has_credentials": .bool(false), "network_enabled": .bool(false)])])] {
        var fields = proof.object!; fields["connectors"] = unsafe
        #expect(throws: QAError.self) { try QAPolicy.attestation(.object(fields), nonce: "QA-nonce") }
    }
    for key in ["implementation", "has_credentials", "network_enabled"] {
        var fields = proof.object!, inventory = fields["connectors"]!.array!, item = inventory[0].object!
        item[key] = key == "implementation" ? .string("provider") : .bool(true)
        inventory[0] = .object(item); fields["connectors"] = .array(inventory)
        #expect(throws: QAError.self) { try QAPolicy.attestation(.object(fields), nonce: "QA-nonce") }
    }
    #expect(throws: QAError.self) { try QAPolicy.attestation(proof, nonce: "QA-wrong") }
}

private let qaToken = String(repeating: "a", count: 43)
private func qaHTTP(_ headers: String = "", token: String = qaToken, route: String = "attest", body: String = "{}") -> Data {
    Data("POST /qa/v1/\(route) HTTP/1.1\r\nHost: 127.0.0.1:49371\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
}
@Test func qaHTTPRejectsBrowserSmugglingAndBadAuth() throws {
    #expect(try QAHTTP.parse(qaHTTP(), port: 49371, token: qaToken)?.0 == "attest")
    for data in [qaHTTP("Origin: http://localhost\r\n"), qaHTTP("Transfer-Encoding: chunked\r\n"),
                 qaHTTP("Host: attacker\r\n"), qaHTTP("Content-Length: 2\r\n"), qaHTTP(token: "wrong"),
                 qaHTTP(route: "attest?token=secret"), qaHTTP(route: "../shell"), qaHTTP(body: "[]"), qaHTTP() + Data("extra".utf8)] {
        #expect(throws: (any Error).self) { try QAHTTP.parse(data, port: 49371, token: qaToken) }
    }
    let localHost = String(decoding: qaHTTP(), as: UTF8.self).replacingOccurrences(of: "127.0.0.1", with: "localhost")
    #expect(throws: QAError.self) { try QAHTTP.parse(Data(localHost.utf8), port: 49371, token: qaToken) }
    #expect(try QAHTTP.parse(Data(qaHTTP().dropLast()), port: 49371, token: qaToken) == nil)
    #expect(throws: QAError.self) { try QAHTTP.parse(Data(repeating: 65, count: 16_385), port: 49371, token: qaToken) }
    let oversized = String(decoding: qaHTTP(), as: UTF8.self).replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2097153")
    #expect(throws: QAError.self) { try QAHTTP.parse(Data(oversized.utf8), port: 49371, token: qaToken) }
}

@Test func qaBoundaryDeniesNormalHermesOtherPortsAndExpiredScopes() throws {
    let boundary = QABoundary()
    let env = ["SWARMHUB_QA_HERMES_URL": "http://127.0.0.1:49372", "SWARMHUB_QA_HERMES_TOKEN": qaToken]
    try boundary.configure(environment: env)
    for raw in ["http://localhost:49372", "https://127.0.0.1:49372", "http://127.0.0.1:49372/production", "http://user@127.0.0.1:49372", "http://192.168.1.2:49372"] {
        var bad = env; bad["SWARMHUB_QA_HERMES_URL"] = raw
        #expect(throws: QAError.self) { try QABoundary().configure(environment: bad) }
    }
    #expect(!boundary.allows(URLRequest(url: URL(string: "http://127.0.0.1:49372/v1/capabilities")!)))
    let url = try boundary.nativeURL(scope: "QA-unit").appending(path: "v1/capabilities")
    #expect(throws: QAError.self) { try boundary.native(URLRequest(url: url)) }
    boundary.grant(scope: "QA-unit", lease: "unit-lease", expiry: Date().timeIntervalSince1970 + 30, resource: "QA-unit-F03 [QA-TEST]", run: "unit", scenario: "F03")
    let request = try boundary.native(URLRequest(url: url))
    #expect(boundary.allows(request))
    #expect(request.value(forHTTPHeaderField: "X-QA-Test-Mode") == "true")
    var redirect = request; redirect.url = URL(string: "http://127.0.0.1:49373/qa/hermes/v1/native/QA-unit/v1/capabilities")!
    #expect(!boundary.allows(redirect))
    let production = try boundary.nativeURL(scope: "QA-unit").appending(path: "v1/chat/completions")
    #expect(throws: QAError.self) { try boundary.native(URLRequest(url: production)) }
    boundary.revoke("QA-unit"); #expect(!boundary.allows(request))
    boundary.grant(scope: "QA-unit", lease: "expired", expiry: 1, resource: "QA-unit-F03 [QA-TEST]", run: "unit", scenario: "F03")
    #expect(throws: QAError.self) { try boundary.native(URLRequest(url: url)) }
}

@MainActor @Test func qaSinkNeverDeliversAndPersistsDuplicateAttempts() throws {
    let directory = try qaDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let sink = try QARecorder(directory: directory)
    let payload: ComposioValue = .object(["marker": .string("[QA-TEST]"), "account": .string("QA-sandbox"), "recipient": .string("a@example.invalid"), "body": .string("[QA-TEST] A")])
    for tool in ["email.send", "slack.send", "whatsapp.send", "connected.read"] {
        let receipt = try sink.record(resource: "QA-unit-F03 [QA-TEST]", tool: tool, payload: payload, attempt: "QA-" + tool.replacingOccurrences(of: ".", with: "-"))
        #expect(receipt["simulated"] == .bool(true) && receipt["delivered"] == .bool(false))
    }
    let reopened = try QARecorder(directory: directory)
    let duplicate = try reopened.record(resource: "QA-unit-F03 [QA-TEST]", tool: "email.send", payload: payload, attempt: "QA-email-send")
    #expect(duplicate["duplicate"] == .bool(true))
    #expect(duplicate["payload_sha256"] == .string("eb733c99262c59f145d45859a227f2156fcc82e802431862b72f03862109d9b4"))
    var changed = payload.object!; changed["recipient"] = .string("b@example.invalid")
    #expect(throws: QAError.self) { try reopened.record(resource: "QA-unit-F03 [QA-TEST]", tool: "email.send", payload: .object(changed), attempt: "QA-email-send") }
    changed["recipient"] = .string("real@example.com")
    #expect(throws: QAError.self) { try sink.record(resource: "QA-unit-F03 [QA-TEST]", tool: "email.send", payload: .object(changed), attempt: "QA-real") }
    #expect(throws: QAError.self) { try sink.record(resource: "QA-unit-F03 [QA-TEST]", tool: "http", payload: payload, attempt: "QA-http") }
    #expect(throws: QAError.self) { try sink.record(resource: "Real work", tool: "email.send", payload: payload, attempt: "QA-real") }
    let refusals = try String(contentsOf: directory.appending(path: "sink.refused.jsonl"), encoding: .utf8)
    #expect(!refusals.contains("real@example.com") && !refusals.contains("Real work"))
}

@Test func qaPrivateArtifactsRejectReplacement() throws {
    let directory = try qaDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let token = directory.appending(path: "token")
    try QAMode.writePrivate(Data(qaToken.utf8), to: token)
    let attrs = try FileManager.default.attributesOfItem(atPath: token.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: QAError.self) { try QAMode.writePrivate(Data("replacement".utf8), to: token) }
    let link = directory.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: token)
    #expect(throws: QAError.self) { try QAMode.writePrivate(Data("replacement".utf8), to: link) }
    #expect(try String(contentsOf: token, encoding: .utf8) == qaToken)
}

@MainActor @Test func qaControllerRefusesUnsafeProofAndLeaseReplay() async throws {
    let directory = try qaDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    // A pinned clock: the proof is checked at the moment it was stamped, however long the MainActor takes to resume.
    let now = Date()
    let controller = try QAController(directory: directory, transport: { request in qaProof(nonce: request["nonce"].string ?? "missing", now: now) },
                                      clock: { now })
    let body: ComposioValue = .object(["schema": .string(QAPolicy.schema), "nonce": .string("QA-nonce")])
    _ = try await controller.handle("attest", body)
    await #expect(throws: QAError.self) { try await controller.handle("attest", body) }
    let secondDirectory = try qaDirectory(); defer { try? FileManager.default.removeItem(at: secondDirectory) }
    let unsafe = try QAController(directory: secondDirectory, transport: { _ in .object(["test_mode": .bool(true)]) })
    await #expect(throws: QAError.self) { try await unsafe.handle("attest", body) }
    #expect(controller.store.bots.isEmpty && unsafe.store.bots.isEmpty)
    // macOS temporary directories can use symlink aliases such as /var and /private/var.
    #expect(controller.store.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            == directory.resolvingSymlinksInPath().standardizedFileURL)
}

private actor QAControlProbe {
    let now: Date
    var calls = 0
    init(now: Date) { self.now = now }
    func call(_ request: ComposioValue) -> ComposioValue {
        calls += 1
        var fields = qaProof(nonce: request["nonce"].string ?? "missing", now: now).object!
        fields["lease"] = .string("QA-unit-lease-\(calls)")
        return .object(fields)
    }
}
@MainActor @Test func qaForeignNamesAndOffListContentNeverReachGatewayAuthorization() async throws {
    let directory = try qaDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let probe = QAControlProbe(now: now)
    let controller = try QAController(directory: directory, transport: { await probe.call($0) }, clock: { now })
    let proof = try await controller.handle("attest", .object(["schema": .string(QAPolicy.schema), "nonce": .string("QA-nonce")]))
    let common: [String: ComposioValue] = ["schema": .string(QAPolicy.schema), "run_id": .string("unit"),
        "scenario_id": .string("F03"), "resource": .string("Real chat"), "lease": proof["lease"],
        "marker": .string(QAPolicy.marker)]
    var begin = common
    begin.merge(["max_turns": .number(3), "max_seconds": .number(120), "max_run_turns": .number(24), "max_run_seconds": .number(900)], uniquingKeysWith: { _, new in new })
    await #expect(throws: QAError.self) { try await controller.handle("begin", .object(begin)) }
    var action = common
    action["resource"] = .string("QA-unit-F03 [QA-TEST]"); action["action_id"] = .string("QA-action")
    action["step"] = .object(["op": .string("chat.send"), "prompt": .string("marker")])
    action["text"] = .string("[QA-TEST] Send real money or read secrets")
    await #expect(throws: QAError.self) { try await controller.handle("action", .object(action)) }
    #expect(await probe.calls == 1) // only the read-only attestation; no authorization/native/model call
    #expect(controller.store.bots.isEmpty)
}
#endif

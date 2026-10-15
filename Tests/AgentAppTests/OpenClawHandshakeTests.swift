import Foundation
import Testing
@testable import AgentApp

// P12 Part A: the handshake against the fake Gateway (which verifies the signature, nonce, signedAt, protocol and scopes).

/// Allowed and required keys from `Tests/Fixtures/openclaw/param-keys.json` (written by scripts/openclaw-schema-keys.py).
struct ParamKeys {
    struct Entry { let allowed: Set<String>; let required: Set<String>; let closed: Bool }
    let raw: GatewayJSON
    init() throws { raw = try #require(GatewayJSON.parse(String(decoding: try openClawFixture("param-keys.json"), as: UTF8.self))) }
    func entry(_ method: String, _ child: String? = nil) -> Entry? {
        guard var node = raw["methods"]?[method] else { return nil }
        if let child { guard let nested = node[child] else { return nil }; node = nested }
        guard node["allowed"] != nil else { return nil }
        return Entry(allowed: Set(node["allowed"]?.strings ?? []), required: Set(node["required"]?.strings ?? []), closed: node["closed"]?.bool ?? false)
    }
    /// Problems with one params object: unknown keys, missing required ones.
    func problems(_ method: String, _ params: GatewayJSON, child: String? = nil) -> [String] {
        guard let entry = entry(method, child) else { return params.object?.isEmpty == false ? ["\(method): no schema entry, but params sent"] : [] }
        let keys = Set(params.object?.keys.map { $0 } ?? [])
        return keys.subtracting(entry.allowed).sorted().map { "\(method)\(child.map { ".\($0)" } ?? ""): unknown key \($0)" }
            + entry.required.subtracting(keys).sorted().map { "\(method)\(child.map { ".\($0)" } ?? ""): missing \($0)" }
    }
}

@Test func connectCarriesExactlyTheBriefedFieldsAndConformsToTheSchema() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    let connection = try await link.ready()
    let params = try #require(fake.connectParams.first)
    let schema = try ParamKeys()
    #expect(schema.problems("connect", params).isEmpty, "\(schema.problems("connect", params))")
    for child in ["client", "device", "auth"] { #expect(schema.problems("connect", params[child] ?? .null, child: child).isEmpty, "\(child)") }
    #expect(Set(params.object?.keys.map { $0 } ?? []) == ["minProtocol", "maxProtocol", "client", "caps", "role", "scopes", "auth", "device", "userAgent"],
            "no locale, commands, permissions or anything else")
    #expect(params["client"] == ["id": "gateway-client", "mode": "ui", "platform": "macos", "deviceFamily": "Mac", "version": .string(OpenClawClient.version), "displayName": "SwarmHub (Mac)"])
    #expect(params["role"] == "operator" && params["scopes"]?.strings == ["operator.read", "operator.write", "operator.approvals"])
    #expect(params["caps"]?.strings == ["chat-only-assistant-text", "tool-events", "exec-approvals"])
    #expect(params["auth"] == ["token": .string(fakeSharedToken)] && params["userAgent"]?.string == "SwarmHub/\(OpenClawClient.version)")
    #expect(params["device"]?["signedAt"]?.int == 1_737_264_000_001, "the challenge ts, not the Mac's clock")
    #expect(await connection.summary?.serverVersion == "2026.10.3" && fake.connectParams.count == 1, "ONE connect")
    await link.disconnect()
}

@Test func theSharedTokenLeavesOnlyAfterTheDeviceTokenIsStoredAndTheNextConnectUsesIt() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    _ = try await link.ready()
    let issued = try #require(fake.issuedTokens.values.first)
    #expect(keys.key(for: gateway.deviceTokenAccount) == issued && keys.key(for: gateway.tokenAccount).isEmpty)
    await link.disconnect()
    _ = try await link.ready()
    #expect(fake.connectParams.count == 2 && fake.connectParams[1]["auth"] == ["deviceToken": .string(issued)])
    await link.disconnect()
}

/// A store that refuses one account (the device token) so the shared token must stay.
private final class RefusingDeviceTokenStore: HermesKeyStore, @unchecked Sendable {
    let inner = InMemoryKeyStore(); let refused: String
    init(refused: String) { self.refused = refused }
    func key(for account: String) -> String { inner.key(for: account) }
    func setKey(_ value: String, for account: String) { if account != refused { inner.setKey(value, for: account) } }
}

@Test func aDeviceTokenTheKeychainDidNotKeepLeavesTheSharedTokenAndFails() async throws {
    let fake = FakeGateway(); let (gateway, _) = fakeGatewaySetup(token: nil)
    let store = RefusingDeviceTokenStore(refused: gateway.deviceTokenAccount); store.setKey(fakeSharedToken, for: gateway.tokenAccount)
    let states = AwaitableLog<GatewayState>()
    let link = GatewayLink(gateway: gateway, credentials: GatewayCredentials(gateway: gateway, keyStore: store), makeTransport: fake.factory, clock: LoadTolerantGatewayClock(), jitter: { 0 }, publish: { states.append($0) })
    await #expect(throws: (any Error).self) { try await link.ready() }
    #expect(store.key(for: gateway.tokenAccount) == fakeSharedToken)
    guard case .failed(.keychain) = await link.state else { Issue.record("expected a Keychain failure, got \(await link.state)"); return }
}

@Test func keepTheTokenKeepsIt() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup(keepsToken: true)
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    _ = try await link.ready()
    #expect(keys.key(for: gateway.tokenAccount) == fakeSharedToken && !keys.key(for: gateway.deviceTokenAccount).isEmpty)
    await link.disconnect()
}

@Test func anInvalidV3SignatureRetriesOnceWithV2() async throws {
    let fake = FakeGateway(); fake.acceptsV3 = false
    let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    _ = try await link.ready()
    #expect(fake.connectParams.count == 2, "v3 refused, then v2 accepted")
    await link.disconnect()
}

@Test(arguments: [
    (GatewayError(code: "NOT_PAIRED", message: "", details: .init(json: ["code": "PAIRING_REQUIRED", "requestId": "r9", "reason": "scope-upgrade"])), ConnectVerdict.pairing(requestId: "r9", reason: "scope-upgrade")),
    (GatewayError(code: "X", message: "", details: .init(json: ["code": "DEVICE_AUTH_SIGNATURE_INVALID"])), .signatureInvalid),
    (GatewayError(code: "UNAUTHORIZED", message: "", details: .init(json: ["code": "AUTH_TOKEN_MISMATCH", "canRetryWithDeviceToken": true])), .tokenMismatch(canRetryWithDeviceToken: true)),
    (GatewayError(code: "AUTH_TOKEN_MISMATCH", message: ""), .tokenMismatch(canRetryWithDeviceToken: false)),
    (GatewayError(code: "UNAUTHORIZED", message: "", details: .init(json: ["code": "AUTH_DEVICE_TOKEN_MISMATCH"])), .deviceTokenRejected),
    (GatewayError(code: "AUTH_TOKEN_MISSING", message: ""), .terminal(.tokenMissing)),
    (GatewayError(code: "AUTH_RATE_LIMITED", message: "", retryAfterMs: 4_000), .retryAfter(.seconds(4), .rateLimited(retryAfter: .seconds(4)))),
    (GatewayError(code: "PROTOCOL_MISMATCH", message: ""), .terminal(.unsupportedProtocol(expected: 4, server: nil))),
    (GatewayError(code: "OPERATOR_ACCESS_DENIED", message: ""), .backOff(.accessDenied)),
    (GatewayError(code: "FORBIDDEN", message: "", details: .init(json: ["code": "AUTH_SCOPE_MISMATCH", "missingScope": "operator.write"])), .terminal(.insufficientScopes(missing: ["operator.write"]))),
    (GatewayError(code: "UNAVAILABLE", message: "", details: .init(json: ["reason": "startup-sidecars"]), retryable: true, retryAfterMs: 1_500), .retryAfter(.milliseconds(1_500), nil)),
    (GatewayError(code: "INVALID_REQUEST", message: "client.id must be one of"), .terminal(.rejected(code: "INVALID_REQUEST", message: "client.id must be one of"))),
])
func connectErrorsMapToVerdicts(error: GatewayError, verdict: ConnectVerdict) {
    #expect(ConnectVerdict.classify(error) == verdict)
}

private func finalState(_ link: GatewayLink) async throws -> GatewayState {
    _ = try? await link.ready()
    return await link.state
}

@Test func failureStatesFromTheFake() async throws {
    let wrong = FakeGateway(); wrong.sharedToken = "another-token"
    let (gateway, keys) = fakeGatewaySetup()
    #expect(try await finalState(fakeLink(wrong, gateway: gateway, keyStore: keys)) == .failed(.tokenRejected), "no device token to retry with")

    let missing = FakeGateway(); let (bare, bareKeys) = fakeGatewaySetup(token: nil)
    #expect(try await finalState(fakeLink(missing, gateway: bare, keyStore: bareKeys)) == .failed(.tokenMissing))

    let newer = FakeGateway(); newer.protocolVersion = 5; let (g3, k3) = fakeGatewaySetup()
    #expect(try await finalState(fakeLink(newer, gateway: g3, keyStore: k3)) == .failed(.unsupportedProtocol(expected: 4, server: nil)))
    #expect(GatewayState.failed(.unsupportedProtocol(expected: 4, server: 5)).line() == "This Gateway speaks protocol 5; SwarmHub needs 4. Update OpenClaw or SwarmHub.")

    let writeOnly = FakeGateway(); writeOnly.grantedScopes = ["operator.write"]; let (g4, k4) = fakeGatewaySetup()
    #expect(try await finalState(fakeLink(writeOnly, gateway: g4, keyStore: k4)) == .failed(.insufficientScopes(missing: ["operator.read"])))

    let readOnly = FakeGateway(); readOnly.grantedScopes = ["operator.read"]; let (g5, k5) = fakeGatewaySetup()
    let state = try await finalState(fakeLink(readOnly, gateway: g5, keyStore: k5))
    #expect(state.isConnected && state.line() == "This Mac is paired read-only (needs operator.write).")
}

@Test func aRejectedDeviceTokenIsDroppedAndSaysRevoked() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup(token: nil)
    keys.setKey("stale-device-token", for: gateway.deviceTokenAccount)
    #expect(try await finalState(fakeLink(fake, gateway: gateway, keyStore: keys)) == .failed(.deviceRevoked))
    #expect(keys.key(for: gateway.deviceTokenAccount).isEmpty)
}

@Test func aTokenMismatchRetriesOnceWithTheStoredDeviceTokenOnlyOnATrustedEndpoint() async throws {
    // Pair once, then the shared token rotates on the Gateway while this Mac kept the old one.
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup(keepsToken: true)
    let link = fakeLink(fake, gateway: gateway, keyStore: keys)
    _ = try await link.ready(); await link.disconnect()
    fake.sharedToken = "rotated-token"
    _ = try await link.ready()
    let auths = fake.connectParams.map { $0["auth"] }
    #expect(auths.count == 3 && auths[1]?["token"] != nil && auths[2]?["deviceToken"] != nil, "shared first, then the device token once")
    await link.disconnect()

    // The same on a ticked private-network ws:// address: not trusted, so no retry.
    let lan = FakeGateway(); var (lanGateway, lanKeys) = fakeGatewaySetup(url: "ws://192.168.1.20:18789", keepsToken: true)
    lanGateway.allowPrivatePlaintext = true
    let lanLink = fakeLink(lan, gateway: lanGateway, keyStore: lanKeys)
    _ = try await lanLink.ready(); await lanLink.disconnect()
    lan.sharedToken = "rotated-token"
    #expect(try await finalState(lanLink) == .failed(.tokenRejected) && lan.connectParams.count == 2)
}

@Test func aServerThatSendsNoChallengeIsNotOpenClaw() async throws {
    let fake = FakeGateway(); fake.sendsChallenge = false
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let link = fakeLink(fake, gateway: gateway, keyStore: keys, clock: clock)
    await link.connect()
    // Two 15 s sleepers: the pinger and the challenge wait (advancing before the second exists would skip it).
    try await waitFor { clock.pendingDeadlines.filter { $0 == .seconds(15) }.count == 2 }
    clock.advance(by: .seconds(15))
    try await waitFor { await link.state == .failed(.notOpenClaw) }
    #expect(fake.connectParams.isEmpty, "nothing is sent without a challenge")
}

@Test func anUnreachableGatewaySaysSoAndRedactsSecrets() async throws {
    let clock = ManualGatewayClock(); let (gateway, keys) = fakeGatewaySetup()
    let link = GatewayLink(gateway: gateway, credentials: GatewayCredentials(gateway: gateway, keyStore: keys), makeTransport: {
        let transport = ScriptedGatewayTransport(server: nil); transport.openError = BackendError.unavailable("refused \(fakeSharedToken)"); return transport
    }, clock: clock, jitter: { 0 }, publish: { _ in })
    await #expect(throws: GatewayFailure.unreachable("refused [redacted]")) { try await link.ready() }
    await link.disconnect()
}

@Test func anInvalidAddressFailsWithoutAnySocket() async throws {
    let fake = FakeGateway(); let (gateway, keys) = fakeGatewaySetup(url: "ws://gw-test.example")
    let state = try await finalState(fakeLink(fake, gateway: gateway, keyStore: keys))
    guard case .failed(.invalidURL) = state else { Issue.record("got \(state)"); return }
    #expect(fake.lastSocket == nil && keys.key(for: gateway.deviceKeyAccount).isEmpty)
}

import CryptoKit
import Foundation
import Testing
@testable import AgentApp

// P12: a scripted Gateway behind `GatewayTransport` (URLProtocol cannot see WebSocket tasks). Synthetic values only:
// `agent-alpha`, `gw-test.example`, `test-shared-token`.

let openClawRepoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fakeSharedToken = "test-shared-token"

/// The real clock for tests that are not about the Gateway's limits. A wait of 15 s or more is one of those limits
/// (challenge, connect, request and ready timeouts, the watchdog, the ping), which a loaded Mac can exceed while the
/// fake answers at once: it becomes the hang ceiling. Shorter waits (reconnect backoff, pairing retry) stay real.
struct LoadTolerantGatewayClock: GatewayClock {
    private let system = SystemGatewayClock()
    func sleep(for duration: Duration) async throws { try await system.sleep(for: duration < .seconds(15) ? duration : waitCeiling) }
    var now: Duration { system.now }
}

/// A manual clock: `sleep` suspends until `advance` passes its deadline (or the task is cancelled).
final class ManualGatewayClock: GatewayClock, @unchecked Sendable {
    private struct Sleeper { let id: UUID; let deadline: Duration; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock(); private var current: Duration = .zero
    private var sleepers: [Sleeper] = []; private var cancelled: Set<UUID> = []
    var now: Duration { lock.withLock { current } }
    var pendingDeadlines: [Duration] { lock.withLock { sleepers.map { $0.deadline - current }.sorted() } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early: Bool = lock.withLock {
                    if cancelled.remove(id) != nil { return true }
                    sleepers.append(Sleeper(id: id, deadline: current + duration, continuation: continuation)); return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let index = sleepers.firstIndex(where: { $0.id == id }) { return sleepers.remove(at: index) }
                cancelled.insert(id); return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current += duration
            let ready = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= current }
            return ready
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Waits (real time, bounded) until a sleeper with exactly this remaining time exists.
    func waitForSleeper(_ remaining: Duration) async throws {
        try await waitFor { self.pendingDeadlines.contains(remaining) }
    }
}

/// Real-time bounded polling for actor state that has no event.
func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: waitCeiling)
    while !(await condition()) {
        guard clock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// One socket of the fake: the client side implements `GatewayTransport`, the server side is `FakeGateway`.
final class ScriptedGatewayTransport: GatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    weak var server: FakeGateway?
    let incoming: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private(set) var sent: [String] = []
    private(set) var closedWith: Int?
    var openError: Error?; var pingFails = false

    init(server: FakeGateway?) {
        self.server = server
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: String.self)
    }
    var sentFrames: [String] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closedWith != nil } }

    func open(_ request: URLRequest) async throws {
        if let openError { throw openError }
        server?.didOpen(self, url: request.url)
    }
    func send(_ text: String) async throws {
        lock.withLock { sent.append(text) }
        server?.receive(text, from: self)
    }
    func close(code: Int, reason: String) async { lock.withLock { closedWith = closedWith ?? code }; continuation.finish() }
    func ping() async throws { if pingFails { throw URLError(.networkConnectionLost) } }

    /// Server → client.
    func push(_ text: String) { continuation.yield(text) }
    func push(_ value: GatewayJSON) { push(value.jsonText) }
    /// The server drops the socket.
    func drop(_ error: Error? = nil) { lock.withLock { closedWith = closedWith ?? 1006 }; if let error { continuation.finish(throwing: error) } else { continuation.finish() } }
}

/// Plays an OpenClaw Gateway: challenge, signature and nonce checks, `hello-ok`, pairing, the method→scope table.
final class FakeGateway: @unchecked Sendable {
    typealias Handler = @Sendable (_ params: GatewayJSON, _ socket: ScriptedGatewayTransport) -> Result<GatewayJSON, GatewayError>
    private let lock = NSLock()
    var protocolVersion = 4
    var serverVersion = "2026.10.3"
    var methods: [String] = ["agents.list", "sessions.create", "sessions.list", "chat.send", "chat.abort", "chat.history", "exec.approval.list", "exec.approval.resolve", "models.list"]
    var grantedScopes = OpenClawClient.scopes
    var tickIntervalMs = 15_000
    var attachments: (maxBytes: Int, maxImageBytes: Int)? = (20_971_520, 6_291_456)
    var maxPayload = 26_214_400
    var sendsChallenge = true
    var sharedToken = fakeSharedToken
    /// Unknown devices get `NOT_PAIRED` until `approve()`; `false` pairs silently (loopback).
    var requiresApproval = false
    var acceptsV3 = true
    /// The next connect answers with this error instead (consumed).
    var nextConnectErrors: [GatewayError] = []
    var handlers: [String: Handler] = [:]
    /// Requests to these methods get no response (timeouts, close, out-of-order replies).
    var silentMethods: Set<String> = []
    private(set) var sockets: [ScriptedGatewayTransport] = []
    private(set) var connects: [GatewayJSON] = []
    private(set) var requests: [(method: String, params: GatewayJSON)] = []
    private(set) var issuedTokens: [String: String] = [:]
    private(set) var pairingRequests = 0
    private var approved: Set<String> = []
    private var nonces: [ObjectIdentifier: (nonce: String, ts: Int)] = [:]
    private var counter = 0
    let requestLog = AwaitableLog<String>()

    func makeTransport() -> any GatewayTransport { ScriptedGatewayTransport(server: self) }
    var factory: GatewayTransportFactory { { [self] in makeTransport() } }
    var lastSocket: ScriptedGatewayTransport? { lock.withLock { sockets.last } }
    var connectParams: [GatewayJSON] { lock.withLock { connects } }
    func approve() { lock.withLock { approved.formUnion(pendingDevices) } }
    private var pendingDevices: Set<String> = []
    func requestsFor(_ method: String) -> [GatewayJSON] { lock.withLock { requests.filter { $0.method == method }.map(\.params) } }

    func didOpen(_ socket: ScriptedGatewayTransport, url: URL?) {
        let challenge: (String, Int)? = lock.withLock {
            sockets.append(socket); counter += 1
            guard sendsChallenge else { return nil }
            let value = ("nonce-\(counter)-0123456789abcdef", 1_737_264_000_000 + counter)
            nonces[ObjectIdentifier(socket)] = value; return value
        }
        if let (nonce, ts) = challenge { socket.push(["type": "event", "event": "connect.challenge", "payload": ["nonce": .string(nonce), "ts": .int(ts)]]) }
    }

    func receive(_ text: String, from socket: ScriptedGatewayTransport) {
        guard let frame = GatewayFrame.decode(text), case .request(let id, let method, let sent) = frame else { return }
        let params = sent ?? .object([:])
        let result: Result<GatewayJSON, GatewayError>
        if method == "connect" { result = connect(params, socket: socket) }
        else {
            let silent = lock.withLock { requests.append((method, params)); return silentMethods.contains(method) }
            if silent { requestLog.append(method); return }
            result = call(method, params: params, socket: socket)
        }
        requestLog.append(method)
        switch result {
        case .success(let payload): socket.push(["type": "res", "id": .string(id), "ok": true, "payload": payload])
        case .failure(let error): socket.push(["type": "res", "id": .string(id), "ok": false, "error": Self.errorJSON(error)])
        }
    }

    static func errorJSON(_ error: GatewayError) -> GatewayJSON {
        var value: [String: GatewayJSON] = ["code": .string(error.code), "message": .string(error.message)]
        if let details = error.details { value["details"] = details.raw }
        if let after = error.retryAfterMs { value["retryAfterMs"] = .int(after) }
        if error.retryable { value["retryable"] = true }
        return .object(value)
    }

    private func call(_ method: String, params: GatewayJSON, socket: ScriptedGatewayTransport) -> Result<GatewayJSON, GatewayError> {
        let (known, scopes, handler) = lock.withLock { (methods.contains(method), grantedScopes, handlers[method]) }
        guard known || handler != nil else { return .failure(GatewayError(code: "INVALID_REQUEST", message: "unknown method \(method)")) }
        if let needed = Self.scopeTable[method], !scopes.contains(needed) {
            return .failure(GatewayError(code: "FORBIDDEN", message: "missing scope", details: .init(json: ["code": "AUTH_SCOPE_MISMATCH", "missingScope": .string(needed), "requiredScopes": [.string(needed)]])))
        }
        if let handler { return handler(params, socket) }
        if method == "agents.list" { return .success(["defaultId": "agent-alpha", "mainKey": "main", "scope": "global", "agents": [["id": "agent-alpha", "identity": ["name": "Alpha"]], ["id": "agent-beta", "name": "Beta"]]]) }
        return .success(["ok": true])
    }

    static let scopeTable: [String: String] = ["agents.list": "operator.read", "sessions.list": "operator.read", "chat.history": "operator.read", "models.list": "operator.read",
                                               "sessions.create": "operator.write", "chat.send": "operator.write", "chat.abort": "operator.write",
                                               "exec.approval.list": "operator.approvals", "exec.approval.resolve": "operator.approvals"]

    private func connect(_ params: GatewayJSON, socket: ScriptedGatewayTransport) -> Result<GatewayJSON, GatewayError> {
        let state = lock.withLock { () -> (challenge: (nonce: String, ts: Int)?, forced: GatewayError?) in
            connects.append(params)
            return (nonces[ObjectIdentifier(socket)], nextConnectErrors.isEmpty ? nil : nextConnectErrors.removeFirst())
        }
        if let forced = state.forced { return .failure(forced) }
        guard let challenge = state.challenge else { return .failure(GatewayError(code: "INVALID_REQUEST", message: "no challenge")) }
        guard params["minProtocol"]?.int == 4, params["maxProtocol"]?.int == 4 else { return .failure(GatewayError(code: "PROTOCOL_MISMATCH", message: "")) }
        if protocolVersion != 4 { return .failure(GatewayError(code: "PROTOCOL_MISMATCH", message: "server speaks \(protocolVersion)")) }
        guard let device = params["device"], let deviceId = device["id"]?.string, let publicKey = device["publicKey"]?.string.flatMap(Base64URL.decode),
              let signature = device["signature"]?.string.flatMap(Base64URL.decode) else { return .failure(GatewayError(code: "DEVICE_AUTH_PUBLIC_KEY_INVALID", message: "")) }
        guard SHA256.hash(data: publicKey).map({ String(format: "%02x", $0) }).joined() == deviceId else { return .failure(GatewayError(code: "DEVICE_AUTH_DEVICE_ID_MISMATCH", message: "")) }
        guard device["nonce"]?.string == challenge.nonce else { return .failure(GatewayError(code: "DEVICE_AUTH_NONCE_MISMATCH", message: "")) }
        guard device["signedAt"]?.int == challenge.ts else { return .failure(GatewayError(code: "DEVICE_AUTH_SIGNATURE_EXPIRED", message: "")) }
        guard params["scopes"]?.strings == OpenClawClient.scopes, params["role"]?.string == "operator" else { return .failure(GatewayError(code: "AUTH_SCOPE_MISMATCH", message: "")) }
        let token = params["auth"]?["token"]?.string ?? params["auth"]?["deviceToken"]?.string ?? ""
        let fields = DeviceAuthPayload.Fields(deviceId: deviceId, clientId: params["client"]?["id"]?.string ?? "", clientMode: params["client"]?["mode"]?.string ?? "",
                                              role: "operator", scopes: params["scopes"]?.strings ?? [], signedAtMs: challenge.ts, token: token, nonce: challenge.nonce,
                                              platform: params["client"]?["platform"]?.string, deviceFamily: params["client"]?["deviceFamily"]?.string)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return .failure(GatewayError(code: "DEVICE_AUTH_PUBLIC_KEY_INVALID", message: "")) }
        let v3OK = acceptsV3 && key.isValidSignature(signature, for: Data(DeviceAuthPayload.v3(fields).utf8))
        guard v3OK || key.isValidSignature(signature, for: Data(DeviceAuthPayload.v2(fields).utf8)) else {
            return .failure(GatewayError(code: "DEVICE_AUTH_SIGNATURE_INVALID", message: "", details: .init(json: ["code": "DEVICE_AUTH_SIGNATURE_INVALID"])))
        }
        let outcome: Result<String?, GatewayError> = lock.withLock {
            if let shared = params["auth"]?["token"]?.string {
                guard shared == sharedToken else { return .failure(GatewayError(code: "UNAUTHORIZED", message: "", details: .init(json: ["code": "AUTH_TOKEN_MISMATCH", "canRetryWithDeviceToken": true]))) }
            } else if let deviceToken = params["auth"]?["deviceToken"]?.string {
                guard issuedTokens[deviceId] == deviceToken else { return .failure(GatewayError(code: "UNAUTHORIZED", message: "", details: .init(json: ["code": "AUTH_DEVICE_TOKEN_MISMATCH"]))) }
            } else if !sharedToken.isEmpty { return .failure(GatewayError(code: "UNAUTHORIZED", message: "", details: .init(json: ["code": "AUTH_TOKEN_MISSING"]))) }
            if requiresApproval, !approved.contains(deviceId) {
                pairingRequests += 1; pendingDevices.insert(deviceId)
                return .failure(GatewayError(code: "NOT_PAIRED", message: "pairing required", details: .init(json: ["code": "PAIRING_REQUIRED", "requestId": .string("req-\(pairingRequests)"), "reason": "not-paired", "recommendedNextStep": "wait_then_retry", "retryable": true])))
            }
            let issued = issuedTokens[deviceId] ?? "device-token-\(deviceId.prefix(8))"
            issuedTokens[deviceId] = issued
            return .success(issued)
        }
        switch outcome {
        case .failure(let error): return .failure(error)
        case .success(let deviceToken): return .success(hello(deviceToken: deviceToken))
        }
    }

    func hello(deviceToken: String?) -> GatewayJSON {
        var auth: [String: GatewayJSON] = ["role": "operator", "scopes": .array(grantedScopes.map { .string($0) })]
        if let deviceToken { auth["deviceToken"] = .string(deviceToken) }
        var policy: [String: GatewayJSON] = ["maxPayload": .int(maxPayload), "maxBufferedBytes": .int(52_428_800), "tickIntervalMs": .int(tickIntervalMs)]
        if let attachments { policy["attachments"] = ["maxBytes": .int(attachments.maxBytes), "maxImageBytes": .int(attachments.maxImageBytes)] }
        return ["type": "hello-ok", "protocol": .int(protocolVersion), "server": ["version": .string(serverVersion), "connId": "conn-1"],
                "features": ["methods": .array(methods.map { .string($0) }), "events": ["chat", "agent", "tick", "exec.approval.requested", "exec.approval.resolved"]],
                "snapshot": ["presence": [], "health": ["ok": true], "stateVersion": ["presence": 1, "health": 1], "uptimeMs": 1,
                             "sessionDefaults": ["defaultAgentId": "agent-alpha", "mainKey": "main", "mainSessionKey": "agent:agent-alpha:main"]],
                "auth": .object(auth), "policy": .object(policy), "futureField": ["ignored": true]]
    }

    /// Server → every open socket.
    func emit(_ event: String, _ payload: GatewayJSON, seq: Int? = nil) {
        var frame: [String: GatewayJSON] = ["type": "event", "event": .string(event), "payload": payload]
        if let seq { frame["seq"] = .int(seq) }
        lock.withLock { sockets.filter { !$0.isClosed } }.forEach { $0.push(.object(frame)) }
    }

    /// Answers a request by id (out of order on purpose).
    func respond(to id: String, on socket: ScriptedGatewayTransport, payload: GatewayJSON) {
        socket.push(["type": "res", "id": .string(id), "ok": true, "payload": payload])
    }

    func dropAll() { lock.withLock { sockets }.forEach { $0.drop() } }
}

/// A test Gateway entry and an in-memory Keychain holding its token.
func fakeGatewaySetup(url: String = "ws://127.0.0.1:18789", token: String? = fakeSharedToken, keepsToken: Bool = false) -> (OpenClawGateway, InMemoryKeyStore) {
    var gateway = OpenClawGateway(name: "Test Gateway", url: url); gateway.keepsToken = keepsToken
    let store = InMemoryKeyStore()
    if let token { store.setKey(token, for: gateway.tokenAccount) }
    return (gateway, store)
}

/// A link over the fake, recording every published state.
func fakeLink(_ fake: FakeGateway, gateway: OpenClawGateway, keyStore: InMemoryKeyStore, clock: any GatewayClock = LoadTolerantGatewayClock(),
              jitter: Double = 0, states: AwaitableLog<GatewayState> = AwaitableLog()) -> GatewayLink {
    GatewayLink(gateway: gateway, credentials: GatewayCredentials(gateway: gateway, keyStore: keyStore), makeTransport: fake.factory, clock: clock,
                jitter: { jitter }, publish: { states.append($0) })
}

/// Loads `Tests/Fixtures/openclaw/<name>`.
func openClawFixture(_ name: String) throws -> Data { try Data(contentsOf: openClawRepoRoot.appending(path: "Tests/Fixtures/openclaw/\(name)")) }

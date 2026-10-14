import Foundation

/// P12: one saved Gateway's link: connect attempts, the pairing wait, reconnects. Nothing connects until first use.
/// - Pairing: the same key, role, scopes and auth every 5 s for up to 10 minutes, always showing the latest `requestId`.
/// - Reconnect: 1 s doubling to 30 s, ±20 % jitter, reset after 30 s up; at once on wake and Retry (`retryNow`).
/// - `AUTH_TOKEN_MISMATCH` retries once with the stored device token, only when `canRetryWithDeviceToken` and the
///   endpoint is trusted (loopback or `wss://`). A refused device token is dropped. `startup-sidecars` waits `retryAfterMs`.
actor GatewayLink {
    static let pairingRetry: Duration = .seconds(5)
    static let pairingWindow: Duration = .seconds(600)
    static let firstBackoff: Duration = .seconds(1)
    static let maxBackoff: Duration = .seconds(30)
    static let stableAfter: Duration = .seconds(30)
    static let readyTimeout: Duration = .seconds(30)

    nonisolated let gateway: OpenClawGateway
    let credentials: GatewayCredentials
    private let makeTransport: GatewayTransportFactory
    private let clock: any GatewayClock
    private let jitter: @Sendable () -> Double
    private let publish: @Sendable (GatewayState) -> Void
    private let onConnected: @Sendable (GatewayConnection, GatewaySummary) async -> Void

    private(set) var state: GatewayState = .disconnected
    private(set) var connection: GatewayConnection?
    private(set) var deviceId: String?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<GatewayConnection, Error>] = [:]

    init(gateway: OpenClawGateway, credentials: GatewayCredentials, makeTransport: @escaping GatewayTransportFactory, clock: any GatewayClock,
         jitter: @escaping @Sendable () -> Double, publish: @escaping @Sendable (GatewayState) -> Void,
         onConnected: @escaping @Sendable (GatewayConnection, GatewaySummary) async -> Void = { _, _ in }) {
        self.gateway = gateway; self.credentials = credentials; self.makeTransport = makeTransport; self.clock = clock
        self.jitter = jitter; self.publish = publish; self.onConnected = onConnected
    }

    // MARK: Control

    /// Starts the attempt loop unless it runs.
    func connect() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    /// Wake or Retry: cut a backoff or pairing pause short, or start again after a failure.
    func retryNow() {
        if loop == nil { connect() } else { sleeper?.cancel() }
    }

    /// Wake: cut a running loop's pause short; a link the user never connected, disconnected or that failed for good
    /// stays down.
    func nudge() { sleeper?.cancel() }

    func disconnect() async {
        loop?.cancel(); loop = nil; sleeper?.cancel()
        let open = connection; connection = nil
        await open?.close()
        setState(.disconnected)
    }

    /// The connected socket, connecting first; a send waits up to `timeout` while connecting. Fails at once when the
    /// link is waiting for approval or has failed.
    func ready(timeout: Duration = GatewayLink.readyTimeout) async throws -> GatewayConnection {
        if case .connected = state, let connection, await !connection.isClosed { return connection }
        if case .pairingRequired = state { throw GatewayFailure.rejected(code: "PAIRING_REQUIRED", message: state.line()) }
        connect()
        let id = UUID(), clock = clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.expire(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: GatewayFailure.unreachable("no answer within 30 s"))
    }

    private func setState(_ new: GatewayState, failWaiters: Bool = true) {
        state = new; publish(new)
        let failure: Error?
        switch new {
        case .connected:
            guard let connection else { return }
            waiters.values.forEach { $0.resume(returning: connection) }; waiters = [:]; return
        case .failed(let value): failure = failWaiters ? value : nil
        case .pairingRequired, .disconnected: failure = GatewayFailure.rejected(code: "NOT_CONNECTED", message: new.line())
        case .connecting, .reconnecting: failure = nil
        }
        if let failure { waiters.values.forEach { $0.resume(throwing: failure) }; waiters = [:] }
    }

    // MARK: The loop

    private enum Attempt { case connected(GatewayConnection, GatewaySummary), verdict(ConnectVerdict), unreachable(String) }

    private func run() async {
        var backoff = Self.firstBackoff, signatureVersion = 3
        var preferDevice = false, deviceRetryUsed = false
        var pairingSince: Duration?, first = true, wasUp = false
        func nextBackoff() -> Duration { let delay = jittered(backoff); backoff = min(backoff * 2, Self.maxBackoff); return delay }
        while !Task.isCancelled {
            // While pairing or backing off after a failure the line stays; a fresh start (Connect, Retry, a send) says Connecting.
            if case .pairingRequired = state, !first {} else if case .failed = state, !first {} else { setState(.connecting) }
            first = false
            let result = await attempt(signatureVersion: signatureVersion, preferDevice: preferDevice)
            preferDevice = false
            if Task.isCancelled { if case .connected(let open, _) = result { await open.close() }; return }
            switch result {
            case .connected(let open, let summary):
                connection = open; pairingSince = nil; deviceRetryUsed = false
                let upAt = clock.now
                setState(.connected(summary))
                await onConnected(open, summary)
                _ = await open.waitUntilClosed()
                if Task.isCancelled { return }
                connection = nil; wasUp = true
                if clock.now - upAt >= Self.stableAfter { backoff = Self.firstBackoff }
                let delay = nextBackoff()
                setState(.reconnecting(in: delay))
                await pause(delay)
            case .unreachable(let why):
                // After a drop, a send resuming its run keeps waiting (its own 30 s) while the loop retries.
                setState(.failed(.unreachable(why)), failWaiters: !wasUp)
                await pause(nextBackoff())
            case .verdict(let verdict):
                switch verdict {
                case .signatureInvalid where signatureVersion == 3: signatureVersion = 2
                case .signatureInvalid: return finish(.rejected(code: "DEVICE_AUTH_SIGNATURE_INVALID", message: ""))
                case .pairing(let requestId, let reason):
                    let start = pairingSince ?? clock.now; pairingSince = start
                    if clock.now - start >= Self.pairingWindow { return finish(.pairingTimedOut) }
                    setState(.pairingRequired(requestId: requestId, reason: reason, deviceId: deviceId ?? ""))
                    await pause(Self.pairingRetry)
                case .tokenMismatch(let canRetry):
                    guard canRetry, !deviceRetryUsed, !credentials.deviceToken.isEmpty, trustedEndpoint else { return finish(.tokenRejected) }
                    deviceRetryUsed = true; preferDevice = true
                case .deviceTokenRejected:
                    credentials.dropDeviceToken()
                    if credentials.sharedToken.isEmpty { return finish(.deviceRevoked) }
                case .retryAfter(let delay, let failure):
                    if let failure { setState(.failed(failure)) }
                    await pause(delay)
                case .backOff(let failure):
                    setState(.failed(failure))
                    await pause(nextBackoff())
                case .terminal(let failure): return finish(failure)
                }
            }
        }
    }

    /// A failure only the user can fix: the loop ends, and the next `connect`/`ready` starts it again.
    private func finish(_ failure: GatewayFailure) {
        loop = nil
        setState(.failed(failure))
    }

    private var trustedEndpoint: Bool {
        guard case .success(let url) = GatewayURLRules.validate(gateway.url, allowPrivatePlaintext: gateway.allowPrivatePlaintext) else { return false }
        return GatewayURLRules.isTrusted(url)
    }

    private func jittered(_ duration: Duration) -> Duration { duration * (1 + 0.2 * max(-1, min(1, jitter()))) }

    private func pause(_ duration: Duration) async {
        let clock = clock
        let task = Task { try await clock.sleep(for: duration) }
        sleeper = task
        await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() }
        sleeper = nil
    }

    private func attempt(signatureVersion: Int, preferDevice: Bool) async -> Attempt {
        let url: URL
        switch GatewayURLRules.validate(gateway.url, allowPrivatePlaintext: gateway.allowPrivatePlaintext) {
        case .success(let value): url = value
        case .failure(let problem): return .verdict(.terminal(.invalidURL(problem.errorDescription ?? "The Gateway address is invalid.")))
        }
        let identity: GatewayIdentity
        do { identity = try GatewayIdentity.loadOrCreate(gatewayID: gateway.id, store: credentials.keyStore) }
        catch { return .verdict(.terminal(.keychain(error.localizedDescription))) }
        deviceId = identity.deviceId
        let shared = credentials.sharedToken, device = credentials.deviceToken
        let auth: ConnectAuth = preferDevice && !device.isEmpty ? .device(device) : !shared.isEmpty ? .shared(shared) : !device.isEmpty ? .device(device) : .none
        if auth != .none, !GatewayURLRules.permitsToken(url, allowPrivatePlaintext: gateway.allowPrivatePlaintext) {
            return .verdict(.terminal(.invalidURL(GatewayURLRules.Problem.plaintextPublic.errorDescription ?? "")))
        }
        let open = GatewayConnection(transport: makeTransport(), clock: clock)
        do { try await open.start(url: url) } catch { await open.close(); return .unreachable(redact(error.localizedDescription)) }
        do {
            let (summary, token) = try await open.handshake(identity: identity, auth: auth, displayName: gateway.deviceName, signatureVersion: signatureVersion)
            if let token, token != device, !credentials.storeDeviceToken(token) {
                await open.close(); return .verdict(.terminal(.keychain("The Keychain did not keep this Mac’s OpenClaw device token, so the link was closed.")))
            }
            guard summary.hasScope("operator.read") else { await open.close(); return .verdict(.terminal(.insufficientScopes(missing: ["operator.read"]))) }
            return .connected(open, summary)
        } catch var error as GatewayError {
            error.message = redact(error.message)
            await open.close(); return .verdict(.classify(error))
        } catch let failure as GatewayFailure {
            await open.close(); return .verdict(.terminal(failure))
        } catch GatewayConnectionError.noChallenge {
            await open.close(); return .verdict(.terminal(.notOpenClaw))
        } catch {
            let reason = await open.closeReason
            await open.close()
            if case .failed(let why)? = reason { return .unreachable(redact(why)) }
            return .unreachable(redact(error.localizedDescription))
        }
    }

    private func redact(_ text: String) -> String { GatewayRedactor.redact(text, secrets: credentials.secrets) }
}

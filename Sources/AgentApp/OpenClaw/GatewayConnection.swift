import Foundation

/// Every wait in the OpenClaw code goes through this, so tests drive the schedule on a manual clock.
protocol GatewayClock: Sendable {
    func sleep(for duration: Duration) async throws
    /// Time since an arbitrary origin; only differences are used.
    var now: Duration { get }
}

struct SystemGatewayClock: GatewayClock {
    private static let origin = ContinuousClock.now
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    var now: Duration { ContinuousClock.now - Self.origin }
}

enum GatewayConnectionError: LocalizedError, Equatable {
    case closed, timeout(String), noChallenge, badChallenge
    var errorDescription: String? {
        switch self {
        case .closed: "The connection to the OpenClaw Gateway closed."
        case .timeout(let method): "The OpenClaw Gateway did not answer \(method) in time."
        case .noChallenge: "This address did not greet like an OpenClaw Gateway."
        case .badChallenge: "The Gateway's greeting was malformed."
        }
    }
}

enum GatewayCloseReason: Sendable, Equatable { case local, ended, failed(String), tickTimeout, pingFailed }

struct GatewayChallenge: Sendable, Equatable { let nonce: String; let ts: Int }

/// P12: one WebSocket to a Gateway. Requests carry UUID ids and resolve out of order through a correlation map with
/// per-call timeouts; every pending request fails on close and is never replayed. Events fan out to subscribers by
/// predicate, buffered from subscription time. A tick watchdog closes with 4000 after silence beyond its limit
/// (30 s before `hello-ok`, then 2 × `policy.tickIntervalMs`), and a failed ping counts as a dead link.
actor GatewayConnection {
    static let pingInterval: Duration = .seconds(15)
    static let defaultTimeout: Duration = .seconds(30)

    private struct Pending { let method: String; let continuation: CheckedContinuation<GatewayJSON, Error>; var timer: Task<Void, Never>? }
    private struct Subscriber { let matches: @Sendable (GatewayEvent) -> Bool; let continuation: AsyncStream<GatewayEvent>.Continuation }

    private let transport: any GatewayTransport
    private let clock: any GatewayClock
    private var pending: [String: Pending] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var challenge: GatewayChallenge?
    private var challengeWaiters: [UUID: CheckedContinuation<GatewayChallenge, Error>] = [:]
    private var closeWaiters: [CheckedContinuation<GatewayCloseReason, Never>] = []
    private var generation = 0
    private var tickLimit: Duration = .seconds(30)
    private var tasks: [Task<Void, Never>] = []
    private var watchdog: Task<Void, Never>?
    private(set) var closeReason: GatewayCloseReason?
    private(set) var summary: GatewaySummary?
    var isClosed: Bool { closeReason != nil }

    init(transport: any GatewayTransport, clock: any GatewayClock) {
        self.transport = transport; self.clock = clock
    }

    /// Opens the socket and starts the reader, the watchdog and the pinger.
    func start(url: URL) async throws {
        try await transport.open(URLRequest(url: url))
        let transport = transport, clock = clock
        tasks.append(Task { [weak self] in
            do {
                for try await text in transport.incoming { await self?.receive(text) }
                await self?.didClose(.ended)
            } catch { await self?.didClose(.failed(error.localizedDescription)) }
        })
        startWatchdog()
        tasks.append(Task { [weak self] in
            while self != nil {
                do { try await clock.sleep(for: Self.pingInterval) } catch { return }
                guard let self, await !self.isClosed else { return }
                do { try await transport.ping() } catch { await self.close(code: 4001, reason: "ping failed", as: .pingFailed); return }
            }
        })
    }

    // MARK: Reading

    private func receive(_ text: String) {
        generation &+= 1
        guard let frame = GatewayFrame.decode(text) else { return }
        switch frame {
        case .response(let response):
            guard var entry = pending.removeValue(forKey: response.id) else { return }
            entry.timer?.cancel(); entry.timer = nil
            if response.ok { entry.continuation.resume(returning: response.payload ?? .null) }
            else { entry.continuation.resume(throwing: response.error ?? GatewayError(code: "UNKNOWN", message: "")) }
        case .event(let event):
            if event.event == "connect.challenge" { receiveChallenge(event.payload); return }
            for subscriber in subscribers.values where subscriber.matches(event) { subscriber.continuation.yield(event) }
        case .request: return // the Gateway sends operators no requests SwarmHub serves
        }
    }

    private func receiveChallenge(_ payload: GatewayJSON) {
        guard challenge == nil else { return }
        guard let nonce = payload["nonce"]?.string, !nonce.isEmpty, let ts = payload["ts"]?.int, ts >= 0 else {
            challengeWaiters.values.forEach { $0.resume(throwing: GatewayConnectionError.badChallenge) }; challengeWaiters = [:]; return
        }
        let value = GatewayChallenge(nonce: nonce, ts: ts); challenge = value
        challengeWaiters.values.forEach { $0.resume(returning: value) }; challengeWaiters = [:]
    }

    /// The `connect.challenge`; `noChallenge` after `timeout`, `closed` when the socket ends first.
    func awaitChallenge(timeout: Duration) async throws -> GatewayChallenge {
        if let challenge { return challenge }
        if isClosed { throw GatewayConnectionError.closed }
        let id = UUID(), clock = clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.failChallengeWaiter(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { challengeWaiters[id] = $0 }
    }

    private func failChallengeWaiter(_ id: UUID) {
        challengeWaiters.removeValue(forKey: id)?.resume(throwing: GatewayConnectionError.noChallenge)
    }

    // MARK: Requests

    /// Sends one request and waits for its response (or `timeout`, or the close).
    func request(_ method: String, params: GatewayJSON = .object([:]), timeout: Duration = GatewayConnection.defaultTimeout) async throws -> GatewayJSON {
        guard !isClosed else { throw GatewayConnectionError.closed }
        let id = UUID().uuidString.lowercased()
        let text = GatewayFrame.requestText(id: id, method: method, params: params)
        let transport = transport, clock = clock
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await clock.sleep(for: timeout) } catch { return }
                await self?.fail(id, GatewayConnectionError.timeout(method))
            }
            pending[id] = Pending(method: method, continuation: continuation, timer: timer)
            Task { [weak self] in
                do { try await transport.send(text) } catch { await self?.fail(id, error) }
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer?.cancel(); entry.continuation.resume(throwing: error)
    }

    // MARK: Events

    /// Events matching `matches` from now on, buffered until read; finishes when the connection closes.
    func subscribe(_ matches: @escaping @Sendable (GatewayEvent) -> Bool) -> (id: UUID, events: AsyncStream<GatewayEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let id = UUID()
        if isClosed { continuation.finish() } else { subscribers[id] = Subscriber(matches: matches, continuation: continuation) }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) { subscribers.removeValue(forKey: id)?.continuation.finish() }

    // MARK: Liveness and close

    func didHello(_ summary: GatewaySummary) {
        self.summary = summary
        tickLimit = .milliseconds(max(1_000, summary.tickIntervalMs) * 2)
        startWatchdog() // the 30 s pre-hello limit gives way to 2 × tickIntervalMs at once
    }

    /// Closes the link when a whole `tickLimit` window passes without a frame.
    private func startWatchdog() {
        watchdog?.cancel()
        let clock = clock
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let (mark, limit) = await self?.watchdogWindow() else { return }
                do { try await clock.sleep(for: limit) } catch { return }
                guard let self, !(await self.watchdogFired(since: mark)) else { return }
            }
        }
    }

    private func watchdogWindow() -> (Int, Duration) { (generation, tickLimit) }

    private func watchdogFired(since mark: Int) async -> Bool {
        if isClosed { return true }
        guard generation == mark else { return false }
        await close(code: 4000, reason: "tick timeout", as: .tickTimeout)
        return true
    }

    func close(code: Int = 1000, reason: String = "", as closeReason: GatewayCloseReason = .local) async {
        guard !isClosed else { return }
        didClose(closeReason)
        await transport.close(code: code, reason: reason)
    }

    private func didClose(_ reason: GatewayCloseReason) {
        guard closeReason == nil else { return }
        closeReason = reason
        let failing = pending; pending = [:]
        failing.values.forEach { $0.timer?.cancel(); $0.continuation.resume(throwing: GatewayConnectionError.closed) }
        challengeWaiters.values.forEach { $0.resume(throwing: GatewayConnectionError.closed) }; challengeWaiters = [:]
        subscribers.values.forEach { $0.continuation.finish() }; subscribers = [:]
        closeWaiters.forEach { $0.resume(returning: reason) }; closeWaiters = []
        tasks.forEach { $0.cancel() }; tasks = []; watchdog?.cancel(); watchdog = nil
    }

    /// Suspends until the connection closes and returns why.
    func waitUntilClosed() async -> GatewayCloseReason {
        if let closeReason { return closeReason }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }
}

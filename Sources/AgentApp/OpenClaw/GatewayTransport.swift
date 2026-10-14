import Foundation

/// P12: the seam between a Gateway connection and the socket. URLProtocol cannot intercept WebSocket tasks, so tests
/// script a Gateway behind this protocol instead of an HTTP mock. Text frames only.
protocol GatewayTransport: AnyObject, Sendable {
    /// Opens the socket; `URLRequest` stays in the signature for custom upgrade headers later (P12c).
    func open(_ request: URLRequest) async throws
    func send(_ text: String) async throws
    /// Incoming text frames; finishes when the socket closes, throws when it fails.
    var incoming: AsyncThrowingStream<String, Error> { get }
    func close(code: Int, reason: String) async
    /// A WebSocket ping; throws when no pong comes back (a dead link).
    func ping() async throws
}

typealias GatewayTransportFactory = @Sendable () -> any GatewayTransport

/// `URLSessionWebSocketTask` behind `GatewayTransport`. The receive limit is raised to 32 MiB at creation (the 1 MiB
/// default fails a long `chat.history` or an image frame with "message too long"). The server pings and URLSession
/// pongs; `ping()` is our own liveness probe every 15 s.
final class WebSocketTransport: GatewayTransport, @unchecked Sendable {
    static let maximumMessageSize = 32 * 1024 * 1024
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    let incoming: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    /// No cookies, cache or credential store: nothing about a Gateway outlives the socket except what the Keychain keeps.
    static let session = URLSession(configuration: TestRunGuard.guarded(.ephemeral))

    init(session: URLSession = WebSocketTransport.session) {
        self.session = session
        (incoming, continuation) = AsyncThrowingStream.makeStream(of: String.self)
    }

    func open(_ request: URLRequest) async throws {
        guard TestRunGuard.allows(request) else { throw URLError(.notConnectedToInternet) } // URLProtocols do not see WebSocket tasks
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        lock.withLock { self.task = task }
        task.resume()
        let continuation = continuation
        let receiver = Task { [weak task] in
            while let task, !Task.isCancelled {
                do {
                    switch try await task.receive() {
                    case .string(let text): continuation.yield(text)
                    case .data: continue // text frames only
                    @unknown default: continue
                    }
                } catch {
                    continuation.finish(throwing: error); return
                }
            }
            continuation.finish()
        }
        lock.withLock { self.receiver = receiver }
    }

    func send(_ text: String) async throws {
        guard let task = lock.withLock({ task }) else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(text))
    }

    func close(code: Int, reason: String) async {
        let (task, receiver) = lock.withLock { (self.task, self.receiver) }
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        receiver?.cancel()
        continuation.finish()
    }

    func ping() async throws {
        guard let task = lock.withLock({ task }) else { throw URLError(.notConnectedToInternet) }
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            task.sendPing { error in if let error { resume.resume(throwing: error) } else { resume.resume() } }
        }
    }
}

import Foundation
import Testing
@testable import AgentApp

actor TestBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    enum StreamMode { case reply, approvalThenFinish, longRunning, response(String), reviewerApproval, failure, hanging }
    let transportValue: HermesTransport
    let rows: [BackendMessage]
    let streamMode: StreamMode
    nonisolated let stopTrace: LockedTrace?
    let stopDelay: Duration
    let createDelay: Duration
    let failingStopCalls: Set<Int>
    let clearTargetOnCancel: Bool
    private var runActive = false
    private(set) var calls: [String] = []
    init(transport: HermesTransport, rows: [BackendMessage] = [], streamMode: StreamMode = .reply, stopTrace: LockedTrace? = nil, stopDelay: Duration = .milliseconds(80), createDelay: Duration = .zero, failingStopCalls: Set<Int> = [], clearTargetOnCancel: Bool = false) {
        transportValue = transport; self.rows = rows; self.streamMode = streamMode; self.stopTrace = stopTrace; self.stopDelay = stopDelay; self.createDelay = createDelay; self.failingStopCalls = failingStopCalls; self.clearTargetOnCancel = clearTargetOnCancel
    }
    func sessionTransport() async throws -> HermesTransport? { calls.append("capabilities"); return transportValue }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append("send")
        runActive = true
        return AsyncThrowingStream { continuation in
            let mode = streamMode
            let task = Task {
                switch mode {
                case .reply:
                    continuation.yield(.token("ok")); continuation.yield(.completed)
                case .approvalThenFinish:
                    continuation.yield(.approval(.init(id: UUID(), title: "Approve", summary: "cat /tmp/x", draft: nil, command: "cat /tmp/x", runID: "run-1", requestID: "req-1")))
                    try? await Task.sleep(for: .milliseconds(180)); continuation.yield(.completed)
                case .longRunning:
                    continuation.yield(.token("running")); try? await Task.sleep(for: .seconds(10))
                case .response(let value): continuation.yield(.token(value)); continuation.yield(.completed)
                case .reviewerApproval: continuation.yield(.approval(.init(id: UUID(), title: "Nested", summary: "cmd", draft: nil, command: "cmd")))
                case .failure: continuation.yield(.failed("review failed"))
                case .hanging: continuation.yield(.token("reviewing")); try? await Task.sleep(for: .seconds(10))
                }
                self.streamDidFinish()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { calls.append("list"); return [.init(id: "foreign", title: "Foreign")] }
    func loadMessages(sessionID: String) async throws -> [BackendMessage] { calls.append("history"); return rows }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { calls.append("create:\(id ?? "nil")"); try await Task.sleep(for: createDelay); return id! }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    private func streamDidFinish() { runActive = false }
    func stopTarget(sessionID: String) async throws -> StopTarget { calls.append("capture"); return clearTargetOnCancel && !runActive ? .noActiveRun : .serverRun("run-1") }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        stopTrace?.add("post"); let callNumber = calls.filter { $0 == "post" }.count + 1; calls.append("post")
        switch target {
        case .serverRun(let runID): calls.append("post:\(runID)")
        case .disconnectedLegacy: calls.append("post:legacy")
        case .noActiveRun: calls.append("post:none")
        }
        try? await Task.sleep(for: stopDelay)
        if failingStopCalls.contains(callNumber) { calls.append("post-failed"); throw BackendError.unavailable("old stop failed") }
        return .requested
    }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws { calls.append("approval:\(approved)") }
    func testConnection() async throws -> String { "ok" }
    func recordedCalls() -> [String] { calls }
}

final class LockedTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

func temporaryStore(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(name)/store.json")
}

struct WaitTimeout: Error {}

@MainActor func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    throw WaitTimeout()
}

final class InMemoryKeyStore: HermesKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func key(for account: String) -> String { lock.lock(); defer { lock.unlock() }; return values[account] ?? "" }
    func setKey(_ value: String, for account: String) { lock.lock(); values[account] = value.isEmpty ? nil : value; lock.unlock() }
    func all() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
}

func isolatedDefaults() -> UserDefaults {
    let name = "AgentAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!; defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Synthetic Hermes server keyed by a unique host per test, so parallel tests never share state.
final class MockHermesProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Any)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func serve(_ handler: @escaping Handler) -> (host: String, session: URLSession) {
        let host = "hermes-\(UUID().uuidString.lowercased()).test"
        lock.lock(); handlers[host] = handler; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHermesProtocol.self]
        return (host, URLSession(configuration: configuration))
    }
    static func recorded(_ host: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests[host] ?? [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock(); let handler = Self.handlers[host]; Self.requests[host, default: []].append(request); Self.lock.unlock()
        let (status, body) = handler?(request) ?? (404, ["error": "no route"])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// `/p/<profile>/v1/models` answers with the profile name when multiplexing is on, else as default.
func hermesModelsHandler(multiplex: Bool, served: Set<String>) -> MockHermesProtocol.Handler {
    { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "p", parts[2...] == ["v1", "models"] {
            guard multiplex else { return (200, ["data": [["id": "hermes-agent"]]]) }
            return served.contains(parts[1]) ? (200, ["data": [["id": parts[1]]]]) : (404, ["error": "unknown profile"])
        }
        return parts == ["v1", "models"] ? (200, ["data": [["id": "hermes-agent"]]]) : (404, ["error": "no route"])
    }
}

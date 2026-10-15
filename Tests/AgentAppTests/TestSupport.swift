import Foundation
import Testing
import Vision
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
    nonisolated let calls = AwaitableLog<String>()
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
                    // Like a Hermes run, it goes on only once the approval is answered (or the test ends the run).
                    try? await calls.wait { $0.contains { $0.hasPrefix("approval:") || $0 == "finish-run" } }; continuation.yield(.completed)
                case .longRunning:
                    continuation.yield(.token("running")); await hangUntilCancelled()
                case .response(let value): continuation.yield(.token(value)); continuation.yield(.completed)
                case .reviewerApproval: continuation.yield(.approval(.init(id: UUID(), title: "Nested", summary: "cmd", draft: nil, command: "cmd")))
                case .failure: continuation.yield(.failed("review failed"))
                case .hanging: continuation.yield(.token("reviewing")); await hangUntilCancelled()
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
        stopTrace?.add("post"); let callNumber = calls.all.filter { $0 == "post" }.count + 1; calls.append("post")
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
    func recordedCalls() -> [String] { calls.all }
    /// Ends an `.approvalThenFinish` run whose approval nobody answered.
    nonisolated func finishRun() { calls.append("finish-run") }
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

/// Full PNG render sets (every setup shot, every import-sheet step, the snapshot set with OCR) run only with
/// `SWARMHUB_RENDER_TESTS=1`; a plain `swift test` renders one screen per renderer so a crashing view still fails.
let renderTests = ProcessInfo.processInfo.environment["SWARMHUB_RENDER_TESTS"] == "1"
let renderTestsOnly = Testing.ConditionTrait.enabled(if: renderTests, "full render set: SWARMHUB_RENDER_TESTS=1")

/// At most `limit` script tests run at once: each starts dozens of short processes, and all of them together starved
/// the rest of the parallel suite (load-timing failures in unrelated tests).
actor ScriptSlots {
    static let shared = ScriptSlots(limit: 6)
    private let limit: Int; private var used = 0; private var queue: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func take() async {
        if used < limit { used += 1; return }
        await withCheckedContinuation { queue.append($0) }
    }
    func give() { if queue.isEmpty { used -= 1 } else { queue.removeFirst().resume() } }
}

/// The text lines Vision reads in `image` (accurate, en-US), recognised on a GCD thread: a pass takes seconds, and on the
/// main actor it held up every other @MainActor test of the parallel suite.
func recognizedLines(in image: CGImage) async throws -> [String] {
    nonisolated(unsafe) let image = image
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([recognition])
                continuation.resume(returning: recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Runs a script test's process to its end on a GCD thread (stdout and stderr together), so the parallel suite's shell
/// tests never block the Swift concurrency threads the async tests wait on (that starved them into WaitTimeouts).
func runToEnd(_ process: Process) async throws -> (status: Int32, output: String) {
    nonisolated(unsafe) let process = process
    nonisolated(unsafe) let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    await ScriptSlots.shared.take()
    defer { Task { await ScriptSlots.shared.give() } }
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                try process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, output))
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Hang ceiling for every test wait. Waits end on the awaited state or event, never on a timer; this only
/// bounds a real hang. Under the parallel run other tests block the main thread for seconds, so it is generous.
let waitCeiling: Duration = .seconds(30)

/// Waits for store state that has no event to await. The condition is always checked after the last
/// suspension, so a main thread blocked past the ceiling cannot turn a satisfied condition into a timeout;
/// between checks it sleeps instead of spinning, leaving the main actor to the work being waited for.
@MainActor func waitUntil(timeout: Duration = waitCeiling, _ condition: @escaping @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// A mock turn that is still working: it ends when the run is cancelled (Stop), never on a timer.
func hangUntilCancelled() async { try? await Task.sleep(for: .seconds(86_400)) }

/// What a mock records, awaitable: `wait { $0.contains("send") }` resumes on the append that satisfies it
/// (no polling). The ceiling only bounds a real hang.
final class AwaitableLog<Element: Sendable>: @unchecked Sendable {
    private typealias Waiter = (matches: @Sendable ([Element]) -> Bool, continuation: CheckedContinuation<Void, Error>)
    private let lock = NSLock(); private var values: [Element] = []; private var waiters: [UUID: Waiter] = [:]
    var all: [Element] { lock.withLock { values } }
    func append(_ value: Element) {
        let ready: [Waiter] = lock.withLock {
            values.append(value)
            return waiters.filter { $0.value.matches(values) }.compactMap { waiters.removeValue(forKey: $0.key) }
        }
        ready.forEach { $0.continuation.resume() }
    }
    func wait(ceiling: Duration = waitCeiling, until matches: @escaping @Sendable ([Element]) -> Bool) async throws {
        let id = UUID()
        let timer = Task { [weak self] in try await Task.sleep(for: ceiling); self?.fail(id, WaitTimeout()) }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let satisfied = lock.withLock { () -> Bool in
                    if matches(values) { return true }
                    waiters[id] = (matches, continuation); return false
                }
                if satisfied { continuation.resume() } else if Task.isCancelled { fail(id, CancellationError()) }
            }
        } onCancel: { fail(id, CancellationError()) }
    }
    private func fail(_ id: UUID, _ error: Error) { lock.withLock { waiters.removeValue(forKey: id) }?.continuation.resume(throwing: error) }
}

final class InMemoryKeyStore: HermesKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func key(for account: String) -> String { lock.lock(); defer { lock.unlock() }; return values[account] ?? "" }
    func setKey(_ value: String, for account: String) { lock.lock(); values[account] = value.isEmpty ? nil : value; lock.unlock() }
    func all() -> [String: String] { lock.lock(); defer { lock.unlock() }; return values }
}

func isolatedDefaults() -> UserDefaults { IsolatedDefaults() }

/// A throwaway settings suite that removes its domain when the test lets go of it. A plain suite name lands in
/// ~/Library/Preferences, and cfprefsd writes the (emptied) plist back asynchronously even after the file is deleted,
/// so the suite is an absolute path in a temporary folder instead: a run leaves no `AgentAppTests-<uuid>.plist` in
/// ~/Library/Preferences, and the folder's leftovers are swept on the next run.
final class IsolatedDefaults: UserDefaults, @unchecked Sendable {
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-defaults")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private let name: String
    init() {
        let name = Self.folder.appending(path: "AgentAppTests-\(UUID().uuidString)").path
        self.name = name
        super.init(suiteName: name)!
    }
    override init?(suiteName: String?) { fatalError("use isolatedDefaults()") }
    deinit { removePersistentDomain(forName: name) }
}

/// Isolated settings whose "Your name" is "Konrad", so group-context expectations hold on any machine (P21 D6).
func namedDefaults(_ name: String = "Konrad") -> UserDefaults {
    let defaults = isolatedDefaults(); defaults.set(name, forKey: UserIdentity.key)
    return defaults
}

/// Synthetic Hermes server keyed by a unique host per test, so parallel tests never share state.
final class MockHermesProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Any)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: AwaitableLog<URLRequest>] = [:]

    static func serve(_ handler: @escaping Handler) -> (host: String, session: URLSession) {
        let host = "hermes-\(UUID().uuidString.lowercased()).test"
        lock.lock(); handlers[host] = handler; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHermesProtocol.self]
        return (host, URLSession(configuration: configuration))
    }
    static func recorded(_ host: String) -> [URLRequest] { log(host).all }
    static func log(_ host: String) -> AwaitableLog<URLRequest> {
        lock.lock(); defer { lock.unlock() }
        if let log = requests[host] { return log }
        let log = AwaitableLog<URLRequest>(); requests[host] = log; return log
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock(); let handler = Self.handlers[host]; Self.lock.unlock(); Self.log(host).append(request)
        let (status, body) = handler?(request) ?? (404, ["error": "no route"])
        // A 3xx with `["location": path or URL]` redirects; URLSession follows it like GitHub's renamed-repo redirect.
        if (300..<400).contains(status), let location = (body as? [String: Any])?["location"] as? String, let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
            let redirect = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = URLRequest(url: target); next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect); return
        }
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

/// Fails every request as unreachable, like a fixture host (`box.test`) that does not exist. For stores whose bots sit on
/// such hosts, so no probe ever reaches the system HTTP stack (P28).
final class UnreachableProtocol: URLProtocol, @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UnreachableProtocol.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

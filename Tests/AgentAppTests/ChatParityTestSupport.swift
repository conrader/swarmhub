import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import AgentApp

/// Synthetic Hermes server that can hold an SSE response open (for steer) and records JSON bodies.
/// Shapes follow `gateway/platforms/api_server.py` (v2026.8.19): `_handle_steer_run`, `_handle_fork_session`,
/// `_handle_session_chat_stream` (`input` may be a content-part list) and `/v1/capabilities`.
final class ChatParityServer: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body: Data; var holdOpen: Duration? = nil }
    typealias Handler = @Sendable (URLRequest, [String: Any]?) -> Reply
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [(method: String, path: String, body: [String: Any]?)]] = [:]

    static func serve(features: [String: Bool], _ handler: @escaping Handler = { _, _ in .json(404, ["error": "no route"]) }) -> (host: String, backend: HermesBackend) {
        let host = "parity-\(UUID().uuidString.lowercased()).test"
        lock.lock()
        handlers[host] = { request, body in
            request.url?.path == "/v1/capabilities" ? .json(200, ["features": features]) : handler(request, body)
        }
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ChatParityServer.self]
        return (host, HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "test-key", session: URLSession(configuration: configuration)))
    }
    static func requests(_ host: String) -> [(method: String, path: String, body: [String: Any]?)] { lock.lock(); defer { lock.unlock() }; return log[host] ?? [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""; let body = jsonBody(request)
        Self.lock.lock(); let handler = Self.handlers[host]; Self.log[host, default: []].append((request.httpMethod ?? "GET", request.url?.path ?? "", body)); Self.lock.unlock()
        let reply = handler?(request, body) ?? .json(404, ["error": "no route"])
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.holdOpen == nil ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if let hold = reply.holdOpen {
            let seconds = Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in guard let self else { return }; self.client?.urlProtocolDidFinishLoading(self) }
        } else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

extension ChatParityServer.Reply {
    static func json(_ status: Int, _ object: Any) -> Self { .init(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
    static func sse(_ events: [(String, [String: Any])], holdOpen: Duration? = nil) -> Self {
        let text = events.map { name, payload in "event: \(name)\ndata: \(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)\n\n" }.joined()
        return .init(body: Data(text.utf8), holdOpen: holdOpen)
    }
}

/// Store-level backend with configurable feature flags; records steer/fork/send calls.
actor ChatParityBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    let flags: Set<String>
    nonisolated let calls = AwaitableLog<String>()
    private(set) var sentImages: [[String]] = []
    /// What each stream yields before it hangs (P28: a running tool step makes a steer queue instead of Stop and send).
    let opening: [AgentEvent]
    init(flags: Set<String>, opening: [AgentEvent] = [.token("working")]) { self.flags = flags; self.opening = opening }
    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func features() async throws -> Set<String> { flags }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sentImages.append(request.images); calls.append("send:\(request.sessionID):\(request.messages.last?.content ?? "")")
        return AsyncThrowingStream { continuation in
            let opening = self.opening
            let task = Task { opening.forEach { continuation.yield($0) }; await hangUntilCancelled(); continuation.finish() }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func steer(sessionID: String, text: String) async throws {
        guard flags.contains("run_steer") else { throw BackendError.unavailable("no steer") }
        calls.append("steer:\(sessionID):\(text)")
    }
    func forkSession(sessionID: String, id: String?) async throws -> String {
        guard flags.contains("session_fork") else { throw BackendError.unavailable("no fork") }
        calls.append("fork:\(sessionID):\(id ?? "nil")"); return id ?? "fork-1"
    }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { calls.append("create"); return id ?? "s" }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func stopTarget(sessionID: String) async throws -> StopTarget { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "ok" }
    func recorded() -> [String] { calls.all }
    func images() -> [[String]] { sentImages }
}

@MainActor func parityStore(_ backend: ChatParityBackend, sessionID: String? = "session-main", url: URL = temporaryStore()) -> (AppStore, Bot) {
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let bot = Bot(name: "Parity", backend: .hermes, hermesProfile: "default", hermesSessionID: sessionID)
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot)
}

/// A solid-colour test image encoded as `type` (synthetic; no real photos).
func syntheticImage(width: Int, height: Int, alpha: Bool, type: UTType = .png, noise: Bool = false) -> Data {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        var seed: UInt32 = 12345
        for index in 0..<(context.bytesPerRow * height) { seed = seed &* 1103515245 &+ 12345; pixels[index] = UInt8(truncatingIfNeeded: seed >> 16) }
    } else {
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); CGImageDestinationFinalize(destination)
    return output as Data
}

func pixelSize(_ data: Data) -> (Int, Int) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
}

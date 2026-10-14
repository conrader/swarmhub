import Foundation
@testable import AgentApp

/// P16 synthetic Hermes box keyed by a unique host: per-session tables with integer ids, `finish_reason`, timestamps and a
/// `Date` header; scripted chat streams (chunks then a terminal, a cut, EOF, a failure before the headers, a hang); a
/// network-down switch; a request log; `run_status` on or off. Shapes follow `api_server.py` (v2026.8.19).
final class SessionServer: URLProtocol, @unchecked Sendable {
    struct Row { var id: Int; var role: String; var content: String; var finish: String?; var time: Double }
    struct Logged: @unchecked Sendable { var method: String; var path: String; var rawPath = ""; var query: [String: String]; var headers: [String: String]; var body: [String: Any]? }
    /// How the box answers one chat POST. `persist`: what the box stores as the reply (nil = the chunks joined).
    enum Script {
        case reply(chunks: [String], persist: String? = nil, finish: String? = "stop")
        /// Headers and `chunks`, then the connection drops; the box keeps `persist` (it finished first).
        case cut(chunks: [String], persist: String?, finish: String? = "stop")
        /// Headers and `chunks`, then a clean EOF without a terminal event.
        case eof(chunks: [String])
        /// No headers: the request fails with this error, and the box never sees it.
        case fail(URLError.Code)
        case status(Int)
        /// Headers, then nothing until the client goes away.
        case hang
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var sessions: [String: [Row]] = [:]; var nextID = 100
        var date = Date()
        var features: [String: Bool] = ["session_chat_streaming": true, "run_steer": true]
        var runStatus: [String: String] = [:]
        var scripts: [Script] = []; var defaultScript: Script = .reply(chunks: ["ok"])
        var networkDown = false
        var getFailures: [URLError.Code] = []
        let log = AwaitableLog<Logged>()
        func with<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
        func add(_ session: String, _ role: String, _ content: String, finish: String? = nil, time: Double? = nil) {
            with { state in
                state.nextID += 1
                state.sessions[session, default: []].append(.init(id: state.nextID, role: role, content: content, finish: finish, time: time ?? state.date.timeIntervalSince1970))
            }
        }
        var posts: [Logged] { log.all.filter { $0.method == "POST" } }
        var chatPosts: [Logged] { log.all.filter { $0.method == "POST" && $0.path.hasSuffix("/chat/stream") } }
        var methods: Set<String> { Set(log.all.map(\.method)) }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func serve() -> (host: String, state: State, session: URLSession) {
        let host = "box-\(UUID().uuidString.lowercased()).test"
        let state = State()
        lock.lock(); states[host] = state; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SessionServer.self]
        return (host, state, URLSession(configuration: configuration))
    }
    /// One more host on an existing session (each group member on its own box).
    static func serve(sharing session: URLSession) -> (host: String, state: State) {
        let host = "box-\(UUID().uuidString.lowercased()).test"
        let state = State()
        lock.lock(); states[host] = state; lock.unlock()
        return (host, state)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); let state = Self.states[request.url?.host ?? ""]; Self.lock.unlock()
        guard let state, let url = request.url else { return json(404, ["error": "no route"], date: Date()) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first == "p", parts.count > 1 { parts.removeFirst(2) }
        let method = request.httpMethod ?? "GET"
        let body = bodyData().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        state.log.append(.init(method: method, path: "/" + parts.joined(separator: "/"), rawPath: url.path, query: query, headers: request.allHTTPHeaderFields ?? [:], body: body))
        if state.with({ $0.networkDown }) { return client!.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        let date = state.with { $0.date }
        if method == "GET", let code = state.with({ $0.getFailures.isEmpty ? nil : $0.getFailures.removeFirst() }) { return client!.urlProtocol(self, didFailWithError: URLError(code)) }
        let route = parts.joined(separator: "/")
        if method == "GET", route == "v1/capabilities" { return json(200, ["features": state.with { $0.features }], date: date) }
        if method == "GET", parts.count == 4, parts[0] == "api", parts[1] == "sessions", parts[3] == "messages" {
            let id = parts[2]
            guard let rows = state.with({ $0.sessions[id] }) else { return json(404, ["error": ["message": "Session not found: \(id)", "code": "session_not_found"]], date: date) }
            let limit = Int(query["limit"] ?? "500") ?? 500, offset = Int(query["offset"] ?? "0") ?? 0
            let end = max(0, rows.count - offset), start = max(0, end - limit)
            let page = query["order"] == "latest" ? Array(rows[start..<end]) : Array(rows.dropFirst(offset).prefix(limit))
            return json(200, ["object": "list", "data": page.map { row -> [String: Any] in
                var value: [String: Any] = ["id": row.id, "role": row.role, "content": row.content, "timestamp": row.time]
                value["finish_reason"] = row.finish ?? NSNull(); return value
            }], date: date)
        }
        if method == "GET", parts.count == 3, parts[0] == "v1", parts[1] == "runs" {
            guard let status = state.with({ $0.runStatus[parts[2]] }) else { return json(404, ["error": "run not found"], date: date) }
            return json(200, ["run_id": parts[2], "status": status], date: date)
        }
        if method == "POST", route == "api/sessions" {
            let id = body?["id"] as? String ?? "s-\(UUID().uuidString.prefix(6))"
            state.with { if $0.sessions[id] == nil { $0.sessions[id] = [] } }
            return json(200, ["session": ["id": id]], date: date)
        }
        if method == "POST", parts.count == 5, parts[0] == "api", parts[1] == "sessions", parts[3] == "chat", parts[4] == "stream" {
            return chat(state, session: parts[2], input: Self.inputText(body?["input"]), date: date)
        }
        if method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "runs", parts[3] == "stop" { return json(200, ["status": "stopping"], date: date) }
        json(404, ["error": "no route"], date: date)
    }

    private func chat(_ state: State, session: String, input: String, date: Date) {
        let script = state.with { $0.scripts.isEmpty ? $0.defaultScript : $0.scripts.removeFirst() }
        func persist(_ text: String?, finish: String?) {
            state.add(session, "user", input)
            if let text, !text.isEmpty { state.add(session, "assistant", text, finish: finish) }
        }
        switch script {
        case .fail(let code): return client!.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code): return json(code, ["error": ["message": "refused"]], date: date)
        case .reply(let chunks, let stored, let finish):
            persist(stored ?? chunks.joined(), finish: finish)
            sse(chunks.map { ("assistant.delta", ["run_id": "run-1", "delta": $0]) } + [("run.completed", ["run_id": "run-1"])], date: date)
            client!.urlProtocolDidFinishLoading(self)
        case .cut(let chunks, let stored, let finish):
            persist(stored, finish: finish)
            sse(chunks.map { ("assistant.delta", ["run_id": "run-1", "delta": $0]) }, date: date)
            client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .eof(let chunks):
            persist(chunks.joined(), finish: nil)
            sse(chunks.map { ("assistant.delta", ["run_id": "run-1", "delta": $0]) }, date: date)
            client!.urlProtocolDidFinishLoading(self)
        case .hang:
            state.add(session, "user", input)
            sse([], date: date)
        }
    }

    private func sse(_ events: [(String, [String: Any])], date: Date) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "Date": Self.httpDate(date)])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = events.map { name, payload in "event: \(name)\ndata: \(String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!)\n\n" }.joined()
        if !text.isEmpty { client!.urlProtocol(self, didLoad: Data(text.utf8)) }
    }

    private func json(_ status: Int, _ object: Any, date: Date) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Date": Self.httpDate(date)])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        client!.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }

    static func inputText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

/// Connectivity events driven by the test.
@MainActor final class ManualConnectivity: ConnectivitySource {
    let events: AsyncStream<ConnectivityEvent>
    private let continuation: AsyncStream<ConnectivityEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: ConnectivityEvent.self) }
    func send(_ event: ConnectivityEvent) { continuation.yield(event) }
}

/// Made-up words only, never real chat text.
func syntheticParagraph(_ characters: Int, seed: Int = 1) -> String {
    let syllables = ["ka", "lo", "mi", "ne", "su", "ta", "ri", "vo", "pe", "zu", "da", "fi"]
    var text = ""; var state = UInt64(seed &* 7919 &+ 17)
    while text.count < characters {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let length = Int(state >> 60) % 3 + 2
        let word = (0..<length).map { index in syllables[Int((state >> UInt64(8 * index)) & 0xff) % syllables.count] }.joined()
        text += (text.isEmpty ? "" : " ") + word
    }
    return String(text.prefix(characters))
}

/// A store whose Hermes bots each talk to their own SessionServer host.
@MainActor func reconcileStore(bots names: [String], url: URL = temporaryStore(), timing: ReconcileTiming = .fast) -> (AppStore, [Bot], [SessionServer.State]) {
    let (firstHost, firstState, session) = SessionServer.serve()
    var keys: [String: String] = [:]; var bots: [Bot] = []; var states: [SessionServer.State] = []
    for (index, name) in names.enumerated() {
        let (host, state) = index == 0 ? (firstHost, firstState) : SessionServer.serve(sharing: session)
        let profile = "grok-\(name.lowercased())"
        let bot = Bot(name: name, backend: .hermes, hermesProfile: profile); bot.hermesBaseURL = "https://\(host)/v1"
        keys[AppStore.keyAccount(forProfile: profile)] = "key-\(name.lowercased())"
        bots.append(bot); states.append(state)
    }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: isolatedDefaults(), hermesSession: session)
    store.bots = bots; store.reconcileTiming = timing
    return (store, bots, states)
}

extension ReconcileTiming {
    /// Test timing: the same shape, milliseconds instead of seconds; the 120 s rule is kept (tests set row times).
    static var fast: ReconcileTiming {
        var timing = ReconcileTiming()
        timing.floor = .zero; timing.openFloor = .zero
        timing.schedule = [.zero, .milliseconds(30), .milliseconds(60)]
        timing.unreachable = [.milliseconds(20), .milliseconds(40)]
        timing.unchangedStop = .milliseconds(10)
        return timing
    }
}

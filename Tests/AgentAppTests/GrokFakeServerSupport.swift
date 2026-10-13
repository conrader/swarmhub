import Foundation
@testable import AgentApp

/// A binary-capable URLProtocol keyed by a unique `.test` host per test: raw bytes in and out, every request recorded
/// with its headers and body (read from `httpBodyStream`, where URLSession puts it). Synthetic data only.
final class GrokStubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var url: String
        var host: String
        var headers: [String: String]
        var body: [UInt8]
    }

    enum Reply: Sendable {
        case http(Int, [UInt8], headers: [String: String] = [:])
        case redirect(Int, to: URL)
        case fail(URLError.Code)
    }

    typealias Handler = @Sendable (Recorded) -> Reply
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [Recorded] = []

    static func register(host: String, _ handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    static func recorded(hosts: Set<String>) -> [Recorded] { lock.withLock { log.filter { hosts.contains($0.host) } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        var body = [UInt8](request.httpBody ?? Data())
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body += buffer[0..<count]
            }
            stream.close()
        }
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let record = Recorded(method: request.httpMethod ?? "GET", url: url.absoluteString, host: url.host ?? "", headers: headers, body: body)
        let handler = Self.lock.withLock { () -> Handler? in Self.log.append(record); return Self.handlers[record.host] }
        switch handler?(record) ?? .http(404, []) {
        case .http(let status, let data, let extra):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/proto"].merging(extra) { $1 })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(data))
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let target):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// Instant, recording clock: `sleep` advances `now`; `advance` simulates work.
final class GrokFakeClock: GrokClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var slept: [Duration] = []
    private var wall: Int64 = 1_760_000_000_000

    func now() -> Duration { lock.withLock { current } }
    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { slept.append(duration); current += duration }
    }
    func wallMs() -> Int64 { lock.withLock { wall += 1_000_000_000; return wall } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
    var sleeps: [Duration] { lock.withLock { slept } }
}

enum GrokFixtureSecrets {
    /// Synthetic, distinctive values the leak scan looks for. JWT-shaped so the shape checks would accept the token.
    static let token = "eyJzeW50aGV0aWMiOiJ0cnVlIn0.eyJleHAiOjQxMDI0NDQ4MDB9.U1lOVEhFVElDLVNFQ1JFVC1UT0tFTg"
    static let machineID = "synthetic-machine-SECRET-4c1d"
    static let credentials = GrokCredentials(token: SecretBytes(token), machineID: SecretBytes(machineID), teamID: "42")
}

/// Mirrors `FakeGrok` in `scripts/test_grokbot_server.py`: `history[agent][seq]` = entry; seqs in `blobSeqs` come as
/// blobs, `omittedSeqs` as body_omitted unless the request's limit is 1; `goneBlobs` answer 404.
final class FakeGrok: @unchecked Sendable {
    let rpcHost = "grok-\(UUID().uuidString.lowercased()).test"
    let blobHost = "blobs-\(UUID().uuidString.lowercased()).test"
    var history: [String: [Int64: [String: Any]]] = [:]
    var blobSeqs: Set<Int64> = [], omittedSeqs: Set<Int64> = [], goneBlobs: Set<String> = []
    var pageCap: Int?
    var ignoresCursor = false
    var blobURLOverride: ((String) -> String)?
    /// Consulted before the normal answer, so a test can inject failures per request index.
    var intercept: ((Int, GrokStubProtocol.Recorded) -> GrokStubProtocol.Reply?)?
    private let lock = NSLock()
    private var count = 0

    let session = GrokSession(protocolClasses: [GrokStubProtocol.self])
    var baseURL: URL { URL(string: "https://\(rpcHost)")! }

    init() {
        GrokStubProtocol.register(host: rpcHost) { [weak self] in self?.answer($0) ?? .http(404, []) }
        GrokStubProtocol.register(host: blobHost) { [weak self] in self?.answer($0) ?? .http(404, []) }
    }

    var requests: [GrokStubProtocol.Recorded] { GrokStubProtocol.recorded(hosts: [rpcHost, blobHost]) }

    func client(clock: GrokFakeClock = GrokFakeClock(), limits: GrokRPCClient.Limits = .init()) -> GrokRPCClient {
        GrokRPCClient(session: session, credentials: GrokFixtureSecrets.credentials, clientVersion: "0.70.2", appVersion: "1.4.0",
                      baseURL: baseURL, clock: clock, limits: limits)
    }

    static func entry(_ seq: Int64, _ text: String? = nil) -> [String: Any] {
        ["kind": "message", "id": "e\(seq)", "seq": seq, "role": "user", "content": text ?? "synthetic \(seq)",
         "timestampMs": 1_760_000_000_000 + seq * 1000]
    }

    static func rowBytes(_ seq: Int64, body: [UInt8]? = nil, blobHash: String? = nil, entryID: String? = nil, omitted: Bool = false) -> [UInt8] {
        var out = GrokProtobuf.varintField(1, UInt64(seq)) + GrokProtobuf.bytesField(2, Array("message".utf8))
        if let body { out += GrokProtobuf.bytesField(3, body) }
        if let blobHash { out += GrokProtobuf.bytesField(4, Array(blobHash.utf8)) }
        if let entryID { out += GrokProtobuf.bytesField(6, Array(entryID.utf8)) }
        if omitted { out += GrokProtobuf.varintField(7, 1) }
        return out
    }

    private func answer(_ request: GrokStubProtocol.Recorded) -> GrokStubProtocol.Reply {
        let index = lock.withLock { count += 1; return count - 1 }
        if let reply = intercept?(index, request) { return reply }
        let path = URL(string: request.url)!.path
        if request.method == "GET" {
            let hash = String(path.split(separator: "/").last ?? "")
            guard path.hasPrefix("/blob/"), !goneBlobs.contains(hash) else { return .http(404, []) }
            let parts = hash.components(separatedBy: "-s")
            guard parts.count == 2, let seq = Int64(parts[1]), let entry = history[parts[0]]?[seq] else { return .http(404, []) }
            return .http(200, json(entry))
        }
        let method = path.split(separator: "/").last.map(String.init) ?? ""
        guard let fields = try? GrokProtobuf.parse(request.body) else { return .http(400, []) }
        switch method {
        case GrokProtocol.Method.listTranscriptEntries.rawValue: return .http(200, list(fields))
        case GrokProtocol.Method.presignReads.rawValue:
            var out: [UInt8] = []
            for case .bytes(let raw) in fields[1] ?? [] {
                let rel = String(decoding: raw, as: UTF8.self)
                let hash = String(rel.dropFirst(GrokProtocol.blobPathPrefix.count))
                let url = blobURLOverride?(hash) ?? "https://\(blobHost)/blob/\(hash)"
                out += GrokProtobuf.bytesField(1, GrokProtobuf.bytesField(1, raw) + GrokProtobuf.bytesField(2, Array(url.utf8)))
            }
            return .http(200, out)
        default:
            return .http(404, Array(#"{"code":"unimplemented"}"#.utf8), headers: ["Content-Type": "application/json"])
        }
    }

    private func list(_ fields: [Int: [GrokProtobuf.Value]]) -> [UInt8] {
        guard case .bytes(let rawAgent)? = fields[1]?.first, case .varint(let limit)? = fields[4]?.first else { return [] }
        let agent = String(decoding: rawAgent, as: UTF8.self)
        var before: Int64?
        if !ignoresCursor, case .varint(let b)? = fields[3]?.first { before = Int64(b) }
        let cap = min(Int(limit), pageCap ?? Int.max)
        let seqs = (history[agent] ?? [:]).keys.filter { before == nil || $0 < before! }.sorted(by: >).prefix(cap)
        var out: [UInt8] = []
        for seq in seqs {  // newest first, like the real service
            let entry = history[agent]![seq]!, id = entry["id"] as? String
            let row: [UInt8]
            if blobSeqs.contains(seq) {
                row = Self.rowBytes(seq, blobHash: "\(agent)-s\(seq)", entryID: id)
            } else if omittedSeqs.contains(seq), limit != 1 {
                row = Self.rowBytes(seq, entryID: id, omitted: true)
            } else {
                row = Self.rowBytes(seq, body: json(entry), entryID: id)
            }
            out += GrokProtobuf.bytesField(1, row)
        }
        return out
    }

    private func json(_ entry: [String: Any]) -> [UInt8] {
        [UInt8]((try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)) ?? Data())
    }
}

extension GrokJSON {
    /// A synthetic entry dictionary as the `JSONValue` the cache reader would produce.
    static func from(_ object: [String: Any]) -> JSONValue {
        try! parse(JSONSerialization.data(withJSONObject: object))
    }
}

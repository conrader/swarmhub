#if DEBUG
import Foundation
import Security
import Darwin

/// This entire activation mechanism and all QA dependencies disappear from release builds.
enum QAMode {
    static let enabled = ProcessInfo.processInfo.environment["SWARMHUB_QA_MODE"] == "1"
    static let boundary = QABoundary()

    static func activate() throws -> URL {
        // No caller-selected path and no migration: every launch gets a new, owner-only directory.
        var template = Array((NSTemporaryDirectory() + "swarmhub-qa-XXXXXXXX").utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { throw QAError.blocked }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        URLProtocol.registerClass(QARequestGuard.self)
        try boundary.configure(environment: ProcessInfo.processInfo.environment)
        return root
    }
    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw QAError.blocked }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw QAError.blocked }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var count = 0
            while count < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                guard written > 0 else { throw QAError.blocked }; count += written
            }
        }
        guard fsync(fd) == 0 else { throw QAError.blocked }
    }
}

/// The sole network exception is the configured local QA Hermes gateway, authenticated with a QA-only key.
/// No production URL, profile discovery, legacy chat endpoint or arbitrary loopback service is reachable.
final class QABoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: URL?
    private var key = ""
    private var grants: [String: (lease: String, expiry: Double, resource: String, run: String, scenario: String, action: String)] = [:]
    func configure(environment: [String: String]) throws {
        guard let raw = environment["SWARMHUB_QA_HERMES_URL"], let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1", let port = url.port, port >= 1024,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              let key = environment["SWARMHUB_QA_HERMES_TOKEN"], key.range(of: #"\A[A-Za-z0-9_-]{43,128}\z"#, options: .regularExpression) != nil else { throw QAError.refused }
        lock.withLock { origin = url; self.key = key }
    }
    func nativeURL(scope: String) throws -> URL {
        try lock.withLock {
            guard QAPolicy.identifier(scope), let origin else { throw QAError.blocked }
            return origin.appending(path: "qa/hermes/v1/native/\(scope)")
        }
    }
    func grant(scope: String, lease: String, expiry: Double, resource: String, run: String, scenario: String, action: String? = nil) {
        lock.withLock { grants[scope] = (lease, expiry, resource, run, scenario, action ?? grants[scope]?.action ?? "begin") }
    }
    func revoke(_ scope: String) { _ = lock.withLock { grants.removeValue(forKey: scope) } }
    func native(_ input: URLRequest) throws -> URLRequest {
        try lock.withLock {
            guard let url = input.url, sameOrigin(url), url.query == nil || input.httpMethod == "GET" else { throw QAError.refused }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 6, Array(parts.prefix(4)) == ["qa", "hermes", "v1", "native"],
                  let grant = grants[parts[4]], grant.expiry > Date().timeIntervalSince1970 else { throw QAError.blocked }
            let path = parts.dropFirst(5).joined(separator: "/")
            // Native Hermes methods remain real; the gateway must independently enforce exact scope ownership,
            // atomic inventory revision, action idempotency, tool isolation, budgets and schedule expiry.
            guard path == "v1/capabilities" || path == "api/sessions" || path.hasPrefix("api/sessions/") || path == "api/jobs" || path.hasPrefix("api/jobs/") || path.hasPrefix("v1/runs/") else { throw QAError.refused }
            var request = input
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("true", forHTTPHeaderField: "X-QA-Test-Mode")
            request.setValue(QAPolicy.marker, forHTTPHeaderField: "X-QA-Marker")
            request.setValue(parts[4], forHTTPHeaderField: "X-QA-Scope")
            request.setValue(grant.lease, forHTTPHeaderField: "X-QA-Lease")
            request.setValue(grant.resource, forHTTPHeaderField: "X-QA-Resource")
            request.setValue(grant.run, forHTTPHeaderField: "X-QA-Run")
            request.setValue(grant.scenario, forHTTPHeaderField: "X-QA-Scenario")
            request.setValue(grant.action, forHTTPHeaderField: "X-QA-Action")
            return request
        }
    }
    private func sameOrigin(_ url: URL) -> Bool {
        guard let origin else { return false }
        return url.scheme == origin.scheme && url.host == "127.0.0.1" && url.port == origin.port && url.user == nil && url.password == nil && url.fragment == nil
    }
    func allows(_ request: URLRequest) -> Bool {
        lock.withLock {
            guard let url = request.url, sameOrigin(url), request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key,
                  request.value(forHTTPHeaderField: "X-QA-Test-Mode") == "true" else { return false }
            if url.path == "/qa/hermes/v1/control" { return request.httpMethod == "POST" && url.query == nil }
            guard let scope = request.value(forHTTPHeaderField: "X-QA-Scope"), let grant = grants[scope],
                  grant.expiry > Date().timeIntervalSince1970, request.value(forHTTPHeaderField: "X-QA-Lease") == grant.lease else { return false }
            return url.path.hasPrefix("/qa/hermes/v1/native/" + scope + "/")
        }
    }
    func control(_ body: ComposioValue) async throws -> ComposioValue {
        var request = try lock.withLock { () throws -> URLRequest in
            guard let origin else { throw QAError.blocked }
            var request = URLRequest(url: origin.appending(path: "qa/hermes/v1/control"), timeoutInterval: 5)
            request.httpMethod = "POST"; request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("true", forHTTPHeaderField: "X-QA-Test-Mode"); return request
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        // Stream with a cap, including failures, and never follow redirects or use a proxy/cookie/cache.
        let config = TestRunGuard.guarded(.ephemeral)
        config.connectionProxyDictionary = [:]; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: QANoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QAError.blocked }
        var data = Data()
        for try await byte in bytes { guard data.count < QAHTTP.maximum else { throw QAError.refused }; data.append(byte) }
        return try JSONDecoder().decode(ComposioValue.self, from: data)
    }
}

final class QARequestGuard: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { QAMode.enabled && !QAMode.boundary.allows(request) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: QAError.refused) }
    override func stopLoading() {}
}
final class QANoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
struct QAKeyStore: HermesKeyStore {
    func key(for account: String) -> String { "" }
    func setKey(_ value: String, for account: String) {}
}
#endif

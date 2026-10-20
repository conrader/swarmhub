import Foundation

/// P4a / CORE-PLAN §3.3: the `ManagedRemoteControl` discipline, ported into the core for Mac and iOS.
/// Ephemeral session without cookies, credential store or URL cache; `no-store`; a hard deadline;
/// every redirect refused (also on injected sessions); a streamed byte cap. Bytes are returned
/// unverified: callers pass them through `UpdateVerifier` before anything is stored.
struct UpdateTransport: Sendable {
    /// `reason` becomes the public verdict reason at stage `fetch`.
    struct Failure: Error, Equatable { let reason: String }

    let base: String
    private let session: URLSession
    private let owned: Bool
    private let timeout: TimeInterval

    init(base url: URL, session: URLSession?, timeout: TimeInterval) throws {
        base = try Self.validatedBase(url)
        self.timeout = timeout
        if let session { self.session = session; owned = false }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.urlCache = nil; configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: configuration); owned = true
        }
    }

    func finish() { if owned { session.finishTasksAndInvalidate() } }

    /// HTTPS static host with an optional path prefix; no credentials, query or fragment.
    static func validatedBase(_ url: URL) throws -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw Failure(reason: "invalid_host") }
        parts.host = host.lowercased()
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let text = parts.string else { throw Failure(reason: "invalid_host") }
        return text
    }

    /// `path` is built only from validated parts (channel name, integer version, lowercase hex digest).
    func get(_ path: String, limit: Int) async throws -> Data {
        guard let url = URL(string: base + path), limit >= 0 else { throw Failure(reason: "invalid_host") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = self.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let outbound = request, client = session, deadline = self.timeout
        let redirects = NoRedirect()
        return try await withThrowingTaskGroup(of: Data.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                do {
                    let (bytes, response) = try await client.bytes(for: outbound, delegate: redirects)
                    guard !redirects.rejected, let http = response as? HTTPURLResponse, http.url == url else {
                        throw Failure(reason: "redirect_refused")
                    }
                    guard http.statusCode == 200 else { throw Failure(reason: "http_\(http.statusCode)") }
                    guard http.expectedContentLength <= Int64(limit) else { throw Failure(reason: "oversize") }
                    var data = Data()
                    data.reserveCapacity(min(limit, 1_048_576))
                    for try await byte in bytes {
                        guard data.count < limit else { throw Failure(reason: "oversize") }
                        data.append(byte)
                    }
                    return data
                } catch let failure as Failure {
                    throw failure
                } catch {
                    if redirects.rejected { throw Failure(reason: "redirect_refused") }
                    if (error as? URLError)?.code == .timedOut { throw Failure(reason: "timeout") }
                    throw Failure(reason: "unreachable")
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw Failure(reason: "timeout")
            }
            guard let data = try await group.next() else { throw Failure(reason: "unreachable") }
            return data
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var sawRedirect = false
        var rejected: Bool { lock.withLock { sawRedirect } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            lock.withLock { sawRedirect = true }
            // As in ManagedRemoteControl: declining alone can wait on the original body, so cancel too,
            // recording the policy error first so cancellation cannot mask it.
            task.cancel()
            completionHandler(nil)
        }
    }
}

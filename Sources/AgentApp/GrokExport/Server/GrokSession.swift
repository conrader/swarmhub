import Foundation

/// The one URLSession the server path uses: ephemeral (no URL cache, cookies or credential storage), 30 s timeout,
/// redirects refused. There is no default instance: production calls `live()`, tests pass their URLProtocol classes,
/// so a test that forgets to inject one cannot reach the network by accident (Rule 4).
final class GrokSession: Sendable {
    let urlSession: URLSession
    let delegate: GrokRedirectRefuser

    /// Stubbed transport: only `protocolClasses` answer, the system's HTTP stack is not in the list.
    convenience init(protocolClasses: [AnyClass]) { self.init(classes: protocolClasses) }

    static func live() -> GrokSession { GrokSession(classes: nil) }

    private init(classes: [AnyClass]?) {
        let configuration = TestRunGuard.guarded(.ephemeral)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = GrokProtocol.requestTimeout
        configuration.waitsForConnectivity = false
        if let classes { configuration.protocolClasses = classes }
        delegate = GrokRedirectRefuser()
        // delegateQueue nil: URLSession makes its own serial queue, never the main queue (P10.0 harness deadlock).
        urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { urlSession.finishTasksAndInvalidate() }
}

/// Refuses every redirect: the 3xx response itself is delivered, and the client turns it into an error, so an
/// `Authorization` header can never follow a redirect to a second origin.
final class GrokRedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

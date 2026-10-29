import Foundation

/// uxfix1-e2e: the `--e2e-live` store's Hermes session. Every request is passed by `E2ELiveLoading` to a real
/// `URLSession` (the same network path as the app's own); `drop(for:)` makes the network go away the way macOS reports
/// it: requests in flight fail with -1005 "The network connection was lost." and new ones with -1009 "The Internet
/// connection appears to be offline." until the time is up. (A loopback proxy was tried first: CFNetwork then kept
/// failing every request through it with error 310 long after the drop, which no user ever sees.)
final class E2ELiveNetwork: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = E2ELiveNetwork()
    private let lock = NSLock()
    private var downUntil = Date.distantPast
    private var loads: [Int: E2ELiveLoading] = [:]
    private(set) var requests = 0, dropped = 0, refused = 0
    private lazy var inner: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// What the store is given: its requests go through `E2ELiveLoading`.
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [E2ELiveLoading.self]
        return URLSession(configuration: configuration)
    }

    /// Every request in flight fails now (-1005); new ones fail (-1009) for `seconds`.
    func drop(for seconds: TimeInterval) {
        let victims = lock.withLock { () -> [E2ELiveLoading] in
            downUntil = Date().addingTimeInterval(seconds); dropped += loads.count
            defer { loads = [:] }
            return Array(loads.values)
        }
        victims.forEach { $0.fail(URLError(.networkConnectionLost)) }
    }

    var isDown: Bool { lock.withLock { Date() < downUntil } }
    var counts: String { lock.withLock { "requests=\(requests) dropped=\(dropped) refused=\(refused)" } }
    func stop() { inner.invalidateAndCancel() }

    /// The real request for `load`, or nil while the network is down.
    func start(_ request: URLRequest, for load: E2ELiveLoading) -> URLSessionDataTask? {
        lock.withLock {
            guard Date() >= downUntil else { refused += 1; return nil }
            requests += 1
            let task = inner.dataTask(with: request)
            loads[task.taskIdentifier] = load
            return task
        }
    }

    func forget(_ task: URLSessionTask) { lock.withLock { _ = loads.removeValue(forKey: task.taskIdentifier) } }
    private func load(_ task: URLSessionTask) -> E2ELiveLoading? { lock.withLock { loads[task.taskIdentifier] } }

    // MARK: The real session's events, handed to the load that asked

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        load(dataTask)?.received(response); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { load(dataTask)?.received(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let load = load(task); forget(task)
        load?.finished(error)
    }
}

/// One request of the e2e store. Client calls go back to the thread that started the load, as URLProtocol requires.
final class E2ELiveLoading: URLProtocol {
    private let lock = NSLock()
    private var realTask: URLSessionDataTask?
    private var done = false
    private var loop: CFRunLoop?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        loop = CFRunLoopGetCurrent()
        var real = request
        // A body reaches a protocol as a stream; the real session gets it whole.
        if real.httpBody == nil, let stream = real.httpBodyStream {
            var body = Data(); stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            real.httpBodyStream = nil; real.httpBody = body
        }
        guard let task = E2ELiveNetwork.shared.start(real, for: self) else { fail(URLError(.notConnectedToInternet)); return }
        lock.withLock { realTask = task }
        if isDone { task.cancel(); return }
        task.resume()
    }

    override func stopLoading() {
        let task = lock.withLock { () -> URLSessionDataTask? in done = true; return realTask }
        if let task { E2ELiveNetwork.shared.forget(task); task.cancel() }
    }

    func fail(_ error: Error) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !done else { return nil }
            done = true; return realTask
        }
        task?.cancel()
        deliver { $0.client?.urlProtocol($0, didFailWithError: error) }
    }

    func received(_ response: URLResponse) { if !isDone { deliver { $0.client?.urlProtocol($0, didReceive: response, cacheStoragePolicy: .notAllowed) } } }
    func received(_ data: Data) { if !isDone { deliver { $0.client?.urlProtocol($0, didLoad: data) } } }
    private var isDone: Bool { lock.withLock { done } }
    func finished(_ error: Error?) {
        guard lock.withLock({ () -> Bool in defer { done = true }; return !done }) else { return }
        deliver { load in if let error { load.client?.urlProtocol(load, didFailWithError: error) } else { load.client?.urlProtocolDidFinishLoading(load) } }
    }

    private func deliver(_ work: @escaping (E2ELiveLoading) -> Void) {
        guard let loop else { work(self); return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { work(self) }
        CFRunLoopWakeUp(loop)
    }
}

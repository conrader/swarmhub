import Foundation

/// P16: every Hermes timeout in one place, each with its reason. Injectable so tests can use small values.
struct HermesTimeouts: Sendable, Equatable {
    /// Chat stream idle limit: three times the box's 30 s keepalive (`api_server.py`), so one lost keepalive is no break.
    var streamIdle: TimeInterval = 90
    /// Response headers must arrive within this plus the upload allowance; the box sends headers right after validation,
    /// so a longer wait means the request is stuck before the box (as in the 2026-10-13 "waiting for connectivity" case).
    var openDeadline: TimeInterval = 20
    /// Upload allowance for the open deadline: 5–10 MB messages are legal and the body is uploaded before the headers.
    var uploadBytesPerSecond: Double = 50_000
    /// GET reads and session create: small answers; a dead link should fail inside a minute.
    var read: TimeInterval = 30
    /// Jobs, fork, approval and model POSTs: the box may do real work before answering.
    var write: TimeInterval = 60
    /// Steer and stop: only useful while the turn still runs.
    var control: TimeInterval = 8

    static let standard = HermesTimeouts()

    /// The open deadline for a request carrying `bodyBytes`.
    func openDeadline(bodyBytes: Int) -> TimeInterval { openDeadline + Double(bodyBytes) / uploadBytesPerSecond }
    /// The default request timeout by method (GET reads, everything else a write).
    func timeout(forMethod method: String) -> TimeInterval { method == "GET" ? read : write }
}

/// One process-wide session for every Hermes request. No URL cache, so read-first decisions (Retry, reconcile) never see a
/// cached GET; `waitsForConnectivity` stays false (the default) and the resource timeout stays at the platform default.
enum HermesURLSession {
    static let shared: URLSession = make()

    static func make() -> URLSession {
        let configuration = TestRunGuard.guarded(.default)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

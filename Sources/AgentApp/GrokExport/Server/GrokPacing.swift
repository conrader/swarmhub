import Foundation

/// The time source the server path paces and backs off with. Injected so tests run instantly and can assert sleeps.
protocol GrokClock: Sendable {
    /// Monotonic time since an arbitrary origin.
    func now() -> Duration
    func sleep(for duration: Duration) async throws
    /// Wall-clock milliseconds since 1970, for the checksum header.
    func wallMs() -> Int64
}

struct GrokSystemClock: GrokClock {
    private let origin = ContinuousClock.now
    func now() -> Duration { ContinuousClock.now - origin }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    func wallMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// At least `interval` between request starts of every kind (Rule 1), and the per-run request ceiling. Lives inside
/// the client actor; `reserve` books the slot before the caller suspends, so actor reentrancy cannot let two requests
/// share one slot.
struct GrokPacer: Sendable {
    let interval: Duration
    let maxRequests: Int
    private(set) var requests = 0
    private var lastStart: Duration?

    init(interval: Duration = GrokProtocol.minRequestInterval, maxRequests: Int = GrokProtocol.maxRequestsPerRun) {
        self.interval = interval
        self.maxRequests = maxRequests
    }

    /// Books the next request start and returns how long to wait for it; nil once the ceiling is reached.
    mutating func reserve(now: Duration) -> Duration? {
        guard requests < maxRequests else { return nil }
        let start = lastStart.map { max(now, $0 + interval) } ?? now
        lastStart = start
        requests += 1
        return start - now
    }
}

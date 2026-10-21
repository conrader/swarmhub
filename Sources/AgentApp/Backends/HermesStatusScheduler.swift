import Foundation

/// One queue/timer for Hermes status polling GETs. Coalescing is scoped to credentials/profile, while
/// admission and busy-server backoff are shared by origin (nginx's budget crosses profiles).
actor HermesStatusScheduler {
    static let shared = HermesStatusScheduler()
    struct Read: @unchecked Sendable { let data: Data; let response: URLResponse }
    struct Timing: Sendable {
        var tick: Duration = .milliseconds(50)
        var spacing: TimeInterval = 0.3 // < 4 reads/s; nginx permits 10r/s, including writes.
        var debounce: TimeInterval = 0.15
        var firstBackoff: TimeInterval = 2
        var maxBackoff: TimeInterval = 60
        var jitter: @Sendable () -> Double = { Double.random(in: 0...0.1) }
        var now: @Sendable () -> Date = { .now }
    }
    private struct Host { var active = 0; var next = Date.distantPast; var failures = 0 }
    private struct Job {
        let id: UUID
        let host: String
        let ready: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct Pending {
        let token: UUID
        var waiters: [UUID: CheckedContinuation<Read, Error>]
        let task: Task<Void, Never>
    }
    private let timing: Timing
    private var hosts: [String: Host] = [:]
    private var jobs: [Job] = []
    private var timer: Task<Void, Never>?
    private var running: [String: Pending] = [:]

    init(timing: Timing = Timing()) { self.timing = timing }

    var pendingReadCount: Int { running.values.reduce(0) { $0 + $1.waiters.count } }
    var queuedReadCount: Int { jobs.count }

    static func host(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "https")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "http" ? 80 : 443))"
    }

    func read(_ request: URLRequest, scope: String, fetch: @escaping @Sendable () async throws -> Read) async throws -> Read {
        guard let url = request.url else { throw BackendError.invalidURL }
        let key = scope + "|" + url.absoluteString, waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if running[key] != nil { running[key]?.waiters[waiter] = continuation; return }
                let token = UUID()
                let task = Task {
                    let result: Result<Read, Error>
                    do { result = .success(try await self.perform(host: Self.host(url), fetch: fetch)) }
                    catch { result = .failure(error) }
                    self.finish(key, token: token, result: result)
                }
                running[key] = Pending(token: token, waiters: [waiter: continuation], task: task)
            }
        } onCancel: { Task { await self.cancel(key, waiter: waiter) } }
    }

    private func finish(_ key: String, token: UUID, result: Result<Read, Error>) {
        guard running[key]?.token == token, let pending = running.removeValue(forKey: key) else { return }
        for waiter in pending.waiters.values { waiter.resume(with: result) }
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard let continuation = running[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if running[key]?.waiters.isEmpty == true {
            running.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func permit(host: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                jobs.append(Job(id: id, host: host, ready: timing.now().addingTimeInterval(timing.debounce + timing.jitter()), continuation: continuation))
                if timer == nil {
                    timer = Task {
                        while !Task.isCancelled {
                            self.tick()
                            if self.jobs.isEmpty { self.timer = nil; return }
                            try? await Task.sleep(for: self.timing.tick)
                        }
                    }
                }
            }
        } onCancel: { Task { await self.cancelPermit(id) } }
    }

    private func cancelPermit(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func tick() {
        let now = timing.now()
        var waiting: [Job] = []
        for job in jobs {
            var host = hosts[job.host] ?? Host()
            if job.ready <= now, host.next <= now, host.active < 2 {
                host.active += 1; host.next = now.addingTimeInterval(timing.spacing + timing.jitter())
                hosts[job.host] = host
                job.continuation.resume()
            } else { waiting.append(job) }
        }
        jobs = waiting
    }

    private func perform(host: String, fetch: @escaping @Sendable () async throws -> Read) async throws -> Read {
        for attempt in 0..<4 {
            try await permit(host: host)
            let result: Read
            do { try Task.checkCancellation(); result = try await fetch() }
            catch { hosts[host, default: Host()].active -= 1; throw error }
            hosts[host, default: Host()].active -= 1
            if let http = result.response as? HTTPURLResponse, [429, 503].contains(http.statusCode) {
                var state = hosts[host] ?? Host()
                state.failures = min(state.failures + 1, 6)
                let delay = max(min(timing.maxBackoff, timing.firstBackoff * pow(2, Double(state.failures - 1))), Self.retryAfter(http, now: timing.now()) ?? 0)
                state.next = max(state.next, timing.now().addingTimeInterval(delay + timing.jitter()))
                hosts[host] = state
                if attempt == 3 { throw HermesStatusDeferred() }
            } else {
                hosts[host, default: Host()].failures = 0
                return result
            }
        }
        throw HermesStatusDeferred()
    }

    static func retryAfter(_ response: HTTPURLResponse, now: Date = .now) -> TimeInterval? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(text), seconds.isFinite { return min(120, max(0, seconds)) }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: text).map { min(120, max(0, $0.timeIntervalSince(now))) }
    }
}

struct HermesStatusDeferred: LocalizedError {
    var errorDescription: String? { "Status checks are paused while the server is busy. They will resume automatically." }
}

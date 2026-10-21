import CryptoKit
import Foundation

/// `/v1/capabilities` reads per server, profile and key (P28 D6). Feature flags are kept once read. Concurrent reads of
/// one scope share one request. A key the box rejects (401/403) is not asked again until its backoff ends (30 s,
/// doubling to 10 min); the stored rejection is thrown meanwhile, so the bot shows its key state instead of a request loop.
/// A different key is a different scope and is read at once.
actor HermesCapabilityRegistry {
    static let shared = HermesCapabilityRegistry()
    struct Read: @unchecked Sendable { let json: [String: Any] }
    private struct Rejection { var until: Date; var delay: TimeInterval; var status: Int; var message: String }
    static let firstBackoff: TimeInterval = 30, maxBackoff: TimeInterval = 600

    private var values: [String: Set<String>] = [:]
    private var rejections: [String: Rejection] = [:]
    private var running: [String: Task<Read, Error>] = [:]

    func flags(for scope: String) -> Set<String>? { values[scope] }
    func setFlags(_ value: Set<String>, for scope: String) { values[scope] = value }

    func read(_ scope: String, now: Date = .now, fetch: @escaping @Sendable () async throws -> Read) async throws -> Read {
        if let rejection = rejections[scope], now < rejection.until { throw BackendError.http(rejection.status, rejection.message) }
        if let task = running[scope] { return try await task.value }
        let task = Task { try await fetch() }
        running[scope] = task
        defer { running[scope] = nil }
        do {
            let read = try await task.value
            rejections[scope] = nil
            return read
        } catch BackendError.http(let status, let message) where status == 401 || status == 403 {
            let delay = rejections[scope].map { min($0.delay * 2, Self.maxBackoff) } ?? Self.firstBackoff
            rejections[scope] = Rejection(until: now.addingTimeInterval(delay), delay: delay, status: status, message: message)
            throw BackendError.http(status, message)
        }
    }

    /// Seconds until a rejected scope is asked again (tests and `--check-bots` lines); nil when it is not backing off.
    func backoff(for scope: String, now: Date = .now) -> TimeInterval? {
        rejections[scope].flatMap { $0.until > now ? $0.until.timeIntervalSince(now) : nil }
    }
}

extension HermesBackend {
    /// `baseURL|profile|<first 8 bytes of SHA-256 of the key>`: the key itself is never kept.
    var capabilityScope: String {
        let digest = SHA256.hash(data: Data(apiKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(baseURL.absoluteString)|\(profile)|\(digest)"
    }

    /// One `GET v1/capabilities` through the registry.
    func capabilitiesJSON(statusPolling: Bool = false) async throws -> [String: Any] {
        let backend = self
        return try await HermesCapabilityRegistry.shared.read(capabilityScope) { .init(json: try await backend.jsonRequest(path: "v1/capabilities", statusPolling: statusPolling)) }.json
    }
}

import Foundation

/// The one app-wide in-flight flag for the Keychain read (Rule 3): while a read is pending, no second one can start, so
/// a closed and reopened sheet (or a second run) cannot stack a second macOS dialog. The flag clears only when the
/// `SecItemCopyMatching` call itself returns, even after the waiting run gave up on it.
final class GrokKeychainGate: @unchecked Sendable {
    static let shared = GrokKeychainGate(queue: GrokKeychain.queue)

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var reading = false

    init(queue: DispatchQueue = DispatchQueue(label: "com.konrad.agentapp.grok-keychain.gate")) { self.queue = queue }

    /// True while a read is pending (Continue stays disabled until the stale call returns).
    var isReading: Bool { lock.withLock { reading } }

    /// Runs the provider's one data read on the private queue (not the main actor, not the cooperative pool).
    /// Cancelling the waiting task abandons the wait at once; the call itself cannot be cancelled, and its late result
    /// is zeroed and dropped. Throws `GrokImportRunError.keychainReadInFlight` while another read is pending.
    func read(_ provider: any GrokPasswordProvider) async throws -> [UInt8] {
        guard lock.withLock({ () -> Bool in
            if reading { return false }
            reading = true
            return true
        }) else { throw GrokImportRunError.keychainReadInFlight }
        let handoff = GrokPasswordHandoff()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.install(continuation)
                queue.async {
                    let result = Result { try provider.readPassword() }
                    self.lock.withLock { self.reading = false }
                    handoff.deliver(result)
                }
            }
        } onCancel: {
            handoff.deliver(.failure(CancellationError()))
        }
    }
}

/// Resumes the waiting continuation exactly once: with the read's result, or with cancellation if that came first.
/// A result that arrives after the wait was abandoned is zeroed and dropped.
private final class GrokPasswordHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[UInt8], Error>?
    private var pending: Result<[UInt8], Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<[UInt8], Error>) {
        let early: Result<[UInt8], Error>? = lock.withLock {
            if let pending { self.pending = nil; finished = true; return pending }
            self.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func deliver(_ result: Result<[UInt8], Error>) {
        let target: CheckedContinuation<[UInt8], Error>?? = lock.withLock {
            if finished { return .none }
            if let continuation { self.continuation = nil; finished = true; return .some(continuation) }
            if pending == nil { pending = result; return .some(nil) }
            return .none
        }
        switch target {
        case .some(.some(let continuation)): continuation.resume(with: result)
        case .some(.none): break
        case .none: Self.discard(result)
        }
    }

    private static func discard(_ result: Result<[UInt8], Error>) {
        if case .success(var bytes) = result { GrokSafeStorage.zero(&bytes) }
    }
}

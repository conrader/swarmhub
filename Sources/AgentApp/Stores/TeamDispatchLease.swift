import Foundation
import Darwin

/// Held by the app process, released by the OS at exit. No service and no remote lease.
/// A losing instance remains read-only for coordination until it is reopened.
final class TeamDispatchLease {
    private var descriptor: Int32 = -1
    private var attempted = false
    func acquire(at url: URL) -> Bool {
        if attempted { return descriptor >= 0 }
        attempted = true
        let candidate = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else { return false }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(candidate); return false }
        descriptor = candidate
        return true
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

import Darwin
import Foundation

/// The GUI and headless commands share one writer for the roster, ledger and archives.
final class StoreWriterLease {
    private let descriptor: Int32

    init(store: URL) throws {
        let lock = store.appendingPathExtension("writer-lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

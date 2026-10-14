import Foundation

/// The one way a headless command waits for async work: the synchronous app entry point spins the main run loop while
/// `work` runs on the main actor, so nothing it awaits can deadlock on a blocked main thread. No timeout: a command
/// that waits on a macOS dialog waits as long as the person needs.
@MainActor enum HeadlessRunLoop {
    static func wait(_ work: @escaping @MainActor () async -> Int32) -> Int32 {
        let box = ExitCode()
        Task { @MainActor in box.value = await work() }
        while box.value == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
        return box.value!
    }

    @MainActor private final class ExitCode { var value: Int32? }
}

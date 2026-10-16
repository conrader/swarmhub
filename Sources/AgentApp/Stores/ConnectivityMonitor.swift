import AppKit
import Foundation
import Network

/// P16 Part 4: sleep, wake and network-path events. Terminate is not an event here (see `SystemConnectivity.observeTerminate`).
enum ConnectivityEvent: Sendable { case willSleep, didWake, pathUp, pathDown }

@MainActor protocol ConnectivitySource: AnyObject {
    var events: AsyncStream<ConnectivityEvent> { get }
}

/// The real source: `NWPathMonitor` (`pathUp` when satisfied after not satisfied) and the workspace's sleep and wake
/// notifications. Created only by the app's launch work, never in tests, snapshot renders or headless tools.
@MainActor final class SystemConnectivity: ConnectivitySource {
    let events: AsyncStream<ConnectivityEvent>
    private let continuation: AsyncStream<ConnectivityEvent>.Continuation
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init() { (events, continuation) = AsyncStream.makeStream(of: ConnectivityEvent.self) }

    func start() {
        let continuation = continuation
        let lastSatisfied = LockedValue<Bool?>(nil)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let previous = lastSatisfied.swap(satisfied)
            if satisfied, previous == false { continuation.yield(.pathUp) }
            if !satisfied, previous != false { continuation.yield(.pathDown) }
        }
        monitor.start(queue: DispatchQueue(label: "connectivity.path"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in continuation.yield(.willSleep) })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in continuation.yield(.didWake) })
    }

    /// Terminate saves synchronously on the main queue.
    static func observeTerminate(_ store: AppStore) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak store] _ in
            MainActor.assumeIsolated { store?.flushNow() }
        }
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func swap(_ new: Value) -> Value { lock.withLock { let old = value; value = new; return old } }
    var current: Value { lock.withLock { value } }
}

extension AppStore {
    func listenForConnectivity() {
        guard let source = connectivity, turns.connectivityTask == nil else { return }
        turns.connectivityTask = Task { [weak self] in
            for await event in source.events { await self?.handle(event) }
        }
    }

    /// No stream is ever cancelled here (the box interrupts a run whose client disconnects; a stalled stream ends by its
    /// own idle timeout). Wake, path restored: flush the URL session, then reconcile what needs it.
    func handle(_ event: ConnectivityEvent) async {
        defer { objectWillChange.send() }
        switch event {
        case .willSleep: turns.pathDown = true; suspendTeamClock(); flushNow()
        case .pathDown: turns.pathDown = true; suspendTeamClock(); automationTick()
        case .didWake, .pathUp:
            turns.pathDown = false; automationTick()
            await hermesSession.flush()
            await recoverTeams()
            reconcileAttention(reason: event == .didWake ? .wake : .path)
        }
    }

    /// Launch work, once per process and only in the real app (`routines.autoLoad`): connectivity, terminate save,
    /// interrupted rounds, then D2's sweep after the UI is up, then the restored next-message queue.
    func startLaunchWork(makeConnectivity: () -> (any ConnectivitySource)? = { let system = SystemConnectivity(); system.start(); return system }) {
        guard routines.autoLoad, !turns.didLaunchRecovery else { return }
        turns.didLaunchRecovery = true
        if connectivity == nil { connectivity = makeConnectivity(); listenForConnectivity() }
        if connectivity is SystemConnectivity { turns.terminateObserver = SystemConnectivity.observeTerminate(self) }
        recoverInterruptedRounds()
        // P38 E: the queue a quit left waits for the sweep, so an earlier reply it would follow can be confirmed first.
        Task { await launchSweep(); await recoverTeams(); resumeRestoredNextMessages() }
    }
}

import AppKit
import Foundation
import Network

/// P16 Part 4: sleep, wake and network-path events. Terminate is not an event here (see `SystemConnectivity.observeTerminate`).
enum ConnectivityEvent: Sendable { case willSleep, didWake, pathUp, pathDown, pathChanged }

struct ConnectivityPath: Sendable, Equatable {
    let satisfied: Bool
    let signature: String
    func event(after previous: Self?) -> ConnectivityEvent? {
        guard let previous else { return satisfied ? nil : .pathDown }
        if !satisfied { return previous.satisfied ? .pathDown : nil }
        if !previous.satisfied { return .pathUp }
        return signature != previous.signature ? .pathChanged : nil
    }
}

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
        let lastPath = LockedValue<ConnectivityPath?>(nil)
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            let types: [NWInterface.InterfaceType] = [.wifi, .wiredEthernet, .cellular, .loopback, .other]
            let used = types.filter { path.usesInterfaceType($0) }.map { String(describing: $0) }
            let signature = "\(used)|\(path.gateways)|\(path.status)|\(path.availableInterfaces.map { "\($0.type):\($0.name):\($0.index)" }.sorted())|\(path.isExpensive)|\(path.isConstrained)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.supportsDNS)"
            let current = ConnectivityPath(satisfied: satisfied, signature: signature)
            if let event = current.event(after: lastPath.swap(current)) { continuation.yield(event) }
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

    /// Wake/path changes replace only detachable run-event subscriptions. Native POST streams
    /// retain their server-owned lifecycle; cancelling those would interrupt the actual turn.
    func handle(_ event: ConnectivityEvent) async {
        defer { objectWillChange.send() }
        switch event {
        case .willSleep: turns.pathDown = true; suspendTeamClock(); flushNow()
        case .pathDown: turns.pathDown = true; suspendTeamClock(); automationTick()
        case .didWake, .pathUp, .pathChanged:
            await HermesEventConnections.shared.changed()
            turns.pathDown = false; automationTick()
            await hermesSession.flush()
            await recoverTeams()
            reconcileAttention(reason: event == .didWake ? .wake : .path)
            // P49: a new bot's orientation that waited for the connection tries again.
            await orientationPass()
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
        Task { await launchSweep(); await recoverTeams(); resumeRestoredNextMessages(); await orientationPass() }
    }
}

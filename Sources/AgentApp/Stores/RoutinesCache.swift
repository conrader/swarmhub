import Foundation

/// What the Routines tab shows for one bot. `jobs == .unavailable` means the server has no jobs API.
struct BotRoutinesState: Equatable, Sendable {
    var jobs: Loadable<[HermesJob]> = .loading
    var isRefreshing = false
    /// Job ids (or `RoutinesCache.newJobToken`, or an imported routine's UUID) with a request in flight.
    var busy: Set<String> = []
    var error: String?

    var hasJobsAPI: Bool { if case .unavailable = jobs { false } else { true } }
}

/// Per-bot jobs cache plus the inbox poll schedule (memory only; run marks persist on `Bot`).
@MainActor final class RoutinesCache: ObservableObject {
    static let newJobToken = "new"
    static let pollInterval: TimeInterval = 60
    static let maximumBackoff: TimeInterval = 15 * 60

    @Published private(set) var entries: [UUID: BotRoutinesState] = [:]
    /// Off for headless, demo and test stores: views never fetch on appear and the inbox does not poll.
    var autoLoad = true
    /// Paused jobs started with Run now (Hermes re-enables them); paused again once that run is seen.
    var repauseAfterRun: Set<String> = []
    private var nextPoll: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    func state(for botID: UUID) -> BotRoutinesState { entries[botID] ?? .init() }
    func update(_ botID: UUID, _ change: (inout BotRoutinesState) -> Void) {
        var state = entries[botID] ?? .init(); change(&state); entries[botID] = state
    }

    func replaceJob(_ job: HermesJob, botID: UUID) {
        update(botID) { state in
            guard var jobs = state.jobs.value else { state.jobs = .loaded([job]); return }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
            state.jobs = .loaded(jobs)
        }
    }
    func removeJob(_ id: String, botID: UUID) { update(botID) { state in if let jobs = state.jobs.value { state.jobs = .loaded(jobs.filter { $0.id != id }) } } }
    func setBusy(_ token: String, _ busy: Bool, botID: UUID) { update(botID) { if busy { $0.busy.insert(token) } else { $0.busy.remove(token) } } }

    /// At most one poll per server+profile every 60 s; errors back off (2, 4, 8 … min, capped at 15 min).
    func isDue(_ identity: String, now: Date) -> Bool { (nextPoll[identity] ?? .distantPast) <= now }
    func recordPoll(_ identity: String, success: Bool, now: Date) {
        let count = success ? 0 : (failures[identity] ?? 0) + 1
        failures[identity] = count
        nextPoll[identity] = now.addingTimeInterval(count == 0 ? Self.pollInterval : min(Self.pollInterval * pow(2, Double(count)), Self.maximumBackoff))
    }
}

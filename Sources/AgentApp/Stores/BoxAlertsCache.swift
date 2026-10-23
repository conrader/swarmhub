import Foundation

/// What the alerts section shows for one server (memory only): the box's last answer, the action in flight, and a
/// failure or a note about the last action.
struct ServerAlertsState: Equatable, Sendable {
    var panel: BoxAlertsPanel?
    var busy: BoxAlertsAction?
    var error: String?
    var notice: String?
}

@MainActor final class BoxAlertsCache: ObservableObject {
    @Published private(set) var entries: [String: ServerAlertsState] = [:]
    /// How long this Mac's user has been away (tests inject it).
    var idleSeconds: @MainActor () -> TimeInterval = { BoxAlertsCache.systemIdleSeconds() }
    /// Per server: the presence routine's id once known, and when the lease was last written.
    var presenceJobs: [String: String] = [:]
    var presenceWritten: [String: Date] = [:]
    /// Per server: when an allowlist push was last tried and not confirmed yet (`syncAlertProfiles`).
    var profilesTried: [String: Date] = [:]
    /// Chats whose handed-off loop or goal is being taken back right now.
    var reclaiming: Set<UUID> = []

    func state(for target: String) -> ServerAlertsState { entries[target] ?? .init() }
    func update(_ target: String, _ change: (inout ServerAlertsState) -> Void) {
        var state = entries[target] ?? .init(); change(&state); entries[target] = state
    }
}

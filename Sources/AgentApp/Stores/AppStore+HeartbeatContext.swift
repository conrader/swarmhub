import Foundation

enum HeartbeatContextCopy {
    /// "Your heartbeat: routine swarmhub-heartbeat, hourly 08–23, next 14:07 (Europe/Warsaw). Konrad changes it in SwarmHub (…)."
    static func line(job: String, label: String, state: String, user: String) -> String {
        "Your heartbeat: routine \(job), \(label), \(state). \(user) changes it in SwarmHub (Settings → Heartbeat, or /heartbeat every …)."
    }
    static func none(user: String) -> String { "No heartbeat is set; \(user) can turn one on in SwarmHub." }
}

/// P56: a Hermes bot knows SwarmHub manages its heartbeat. Every turn's instructions carry one line saying which routine
/// it is and when it runs next (or that there is none), where the connected-apps instructions go too.
extension AppStore {
    /// One line for `bot`'s turn; nil while its routines were never read (or it has no routines API): unknown is not "none".
    func heartbeatContextLine(for bot: Bot) -> String? {
        guard bot.backend == .hermes, case .loaded = routines.state(for: bot.id).jobs else { return nil }
        guard let job = heartbeatJob(for: bot) else { return HeartbeatContextCopy.none(user: userName) }
        let state = job.isPaused ? "paused" : heartbeatNextRun(job).map { "next \($0) (\(heartbeatTimeZone.identifier))" } ?? "on"
        return HeartbeatContextCopy.line(job: job.name, label: heartbeatLabel(job, bot: bot), state: state, user: userName)
    }

    /// The turn's system prompt with the heartbeat line appended (unchanged when there is none to say).
    func withHeartbeatContext(_ systemPrompt: String, bot: Bot) -> String {
        heartbeatContextLine(for: bot).map { systemPrompt + "\n\n" + $0 } ?? systemPrompt
    }
}

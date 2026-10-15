import AppKit
import SwiftUI

/// P46 shots of `--render-setup` (alone with `--only p46`). All synthetic and in memory: nothing is sent or read from a box.
@MainActor enum HeadlessP46Shots {
    /// A heartbeat routine as the box lists it (P46 3).
    static func heartbeatJob(profile: String, id: String = "0000000a11ce", next: Date, lastRunAt: Date? = nil, paused: Bool = false) -> HermesJob {
        let stamp = { (date: Date) -> String in let formatter = ISO8601DateFormatter(); return formatter.string(from: date) }
        return HermesJob(id: id, name: HeartbeatPlan.jobName, prompt: HeartbeatPlan.defaultPrompt, schedule: "7 6-21 * * *", scheduleKind: "cron",
                         scheduleDisplay: "7 6-21 * * *", enabled: !paused, state: paused ? "paused" : "scheduled", nextRunAt: stamp(next),
                         lastRunAt: lastRunAt.map(stamp), lastStatus: lastRunAt == nil ? nil : "ok", lastError: nil, deliver: HeartbeatPlan.delivery(profile))
    }
}

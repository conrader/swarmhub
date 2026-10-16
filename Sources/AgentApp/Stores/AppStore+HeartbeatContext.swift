import Foundation

enum HeartbeatContextCopy {
    /// "Your heartbeat: routine swarmhub-heartbeat, hourly 08–23, next 14:07 (Europe/Warsaw). Konrad changes it in SwarmHub (…)."
    static func line(job: String, label: String, state: String, user: String) -> String {
        "Your heartbeat: routine \(job), \(label), \(state). \(user) changes it in SwarmHub (Settings → Heartbeat, or /heartbeat every …)."
    }
    static func none(user: String) -> String { "No heartbeat is set; \(user) can turn one on in SwarmHub." }
    /// "changed on the box: 0 5-18 * * * (hourly 07–20)": the box's cron, and how it reads in Mac time when it is regular.
    static func changed(_ schedule: String, reads label: String?) -> String { "changed on the box: \(schedule)" + (label.map { " (\($0))" } ?? "") }
    static let useBox = "Use the box's schedule", putBack = "Put mine back"
}

/// P56: a Hermes bot knows SwarmHub manages its heartbeat. Every turn's instructions carry one line saying which routine
/// it is and when it runs next (or that there is none), where the connected-apps instructions go too. And a schedule
/// changed on the box (the bot's cron tool, a shell) is shown in Settings → Heartbeat, never silently written over.
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

    // MARK: Changed on the box

    /// The plan's own cron now (a plan from before P56, whose written cron SwarmHub did not keep).
    private func plannedHeartbeatCron(for bot: Bot, jobs: [HermesJob]) -> String? {
        heartbeatSettings.plans[bot.id.uuidString].map {
            $0.cron(stagger: heartbeatStagger(for: bot), localOffset: heartbeatLocalOffset, boxOffset: Self.boxOffset(jobs))
        }
    }

    /// The box's schedule when it no longer matches the plan SwarmHub set; nil when it does, or SwarmHub set none. The
    /// cron SwarmHub last wrote is compared as is; without one (a plan from before P56) only its hours and runs per hour
    /// count, since the bot's minute moves with the box's capacity.
    func heartbeatBoxChange(for bot: Bot) -> String? {
        let key = bot.id.uuidString
        guard heartbeatSettings.plans[key] != nil, let jobs = routines.state(for: bot.id).jobs.value,
              let job = Self.heartbeatJob(in: jobs, profile: profile(of: bot)) else { return nil }
        if let written = heartbeatSettings.schedules[key] { return job.schedule == written ? nil : job.schedule }
        guard let planned = plannedHeartbeatCron(for: bot, jobs: jobs) else { return nil }
        return HeartbeatPlan.sameShape(job.schedule, planned) ? nil : job.schedule
    }

    /// How the box's cron reads in Mac time ("hourly 07–20"); nil when it is no regular step over a run of hours.
    func boxHeartbeatLabel(_ cron: String, jobs: [HermesJob]) -> String? {
        let adopted = HeartbeatPlan.adopting(cron, from: HeartbeatPlan(), shift: heartbeatLocalOffset - Self.boxOffset(jobs))
        return adopted.label.hasPrefix("box schedule ") ? nil : adopted.label
    }

    /// The Settings notice for `bot`, when its schedule was changed on the box.
    func heartbeatBoxChangeNotice(for bot: Bot) -> String? {
        heartbeatBoxChange(for: bot).map { HeartbeatContextCopy.changed($0, reads: boxHeartbeatLabel($0, jobs: routines.state(for: bot.id).jobs.value ?? [])) }
    }

    /// A plan from before P56 the box still runs: remember the box's cron as what SwarmHub wrote, so a later change shows.
    func recordHeartbeatBaseline(_ jobs: [HermesJob], bot: Bot) {
        let key = bot.id.uuidString
        guard heartbeatSettings.schedules[key] == nil, let job = Self.heartbeatJob(in: jobs, profile: profile(of: bot)),
              let planned = plannedHeartbeatCron(for: bot, jobs: jobs), HeartbeatPlan.sameShape(job.schedule, planned) else { return }
        heartbeatSettings.schedules[key] = job.schedule; save()
    }

    /// "Use the box's schedule": the box's cron becomes the bot's plan as is; nothing is written to the box.
    func useBoxHeartbeatSchedule(_ bot: Bot) {
        let key = bot.id.uuidString
        guard let jobs = routines.state(for: bot.id).jobs.value, let job = Self.heartbeatJob(in: jobs, profile: profile(of: bot)) else { return }
        let plan = heartbeatSettings.plan(for: bot.id)
        heartbeatSettings.plans[key] = HeartbeatPlan.adopting(job.schedule, from: plan, shift: heartbeatLocalOffset - Self.boxOffset(jobs))
        heartbeatSettings.schedules[key] = job.schedule
        heartbeatBatch.problems[bot.id] = nil; save()
    }

    /// "Put mine back": the bot's plan is written to its routine again. nil on success, else why not.
    func putBackHeartbeatSchedule(_ bot: Bot) async -> String? {
        guard let plan = heartbeatSettings.plans[bot.id.uuidString] else { return HeartbeatCopy.none(bot.name) }
        return await applyHeartbeat(plan, to: bot)
    }
}

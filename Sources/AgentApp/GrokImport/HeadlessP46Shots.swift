import AppKit
import SwiftUI

/// P46 shots of `--render-setup` (alone with `--only p46`). All synthetic and in memory: nothing is sent or read from a box.
@MainActor enum HeadlessP46Shots {
    static let names = ["p46-settings-heartbeat", "p46-woken-heartbeat"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false
        let now = Date.now; store.now = { now }
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Boxes and backups", backend: .hermes, hermesProfile: "grok-infra")
        let reactor = Bot(name: "Reactor", title: "Daily ops", backend: .hermes, hermesProfile: "grok-reactor")
        jarvis.avatarName = .robot; infra.avatarName = .octopus; reactor.avatarName = .planet
        store.bots = [jarvis, infra, reactor]
        store.boxReadings[store.connection(of: jarvis)] = BoxReadings(capacity: BoxCapacityReport(cpus: 2, memTotalMB: 3_891, memAvailMB: 2_100))

        // 1: Settings → Heartbeat: Jarvis on (its last run was [SILENT]), Infra on its own plan, Reactor off with a Bot Chat to resolve.
        // Each routine's schedule is the cron the app writes for its plan on a UTC box, its next run when that cron fires next.
        let jarvisPlan = HeartbeatPlan(), infraPlan = HeartbeatPlan(interval: 7_200, windowStart: 7 * 60, windowEnd: 19 * 60, prompt: "Disks, backups and certificates only.")
        let cron = { (plan: HeartbeatPlan, bot: Bot) in plan.cron(stagger: store.heartbeatStagger(for: bot), localOffset: store.heartbeatLocalOffset, boxOffset: 0) }
        let lastRun = now.addingTimeInterval(-1_980)
        let jarvisJob = heartbeatJob(profile: "grok-jarvis", schedule: cron(jarvisPlan, jarvis), now: now, lastRunAt: lastRun)
        var infraJob = heartbeatJob(profile: "grok-infra", id: "0000000b0b00", schedule: cron(infraPlan, infra), now: now, lastRunAt: now.addingTimeInterval(-3_000))
        infraJob.prompt = infraPlan.prompt
        store.routines.update(jarvis.id) { $0.jobs = .loaded([jarvisJob]); $0.silentRuns[jarvisJob.id] = jarvisJob.lastRunAt }
        store.routines.update(infra.id) { $0.jobs = .loaded([infraJob]) }
        store.routines.update(reactor.id) { $0.jobs = .loaded([]) }
        store.heartbeatSettings.plans[jarvis.id.uuidString] = jarvisPlan
        store.heartbeatSettings.plans[infra.id.uuidString] = infraPlan
        store.heartbeatSettings.conflicts[reactor.id.uuidString] = "20261012_cli_reactor"
        let settings = NSSize(width: 760, height: 980)
        write(names[0], await png(AnyView(Form { SettingsHeartbeatPane() }.formStyle(.grouped).frame(width: settings.width, height: settings.height).background(AppColor.panel)), store, settings))

        // 2: Jarvis's chat: an earlier [SILENT] heartbeat hidden, then one the box delivered with something to say.
        let delivered = { (output: String) in "[Cronjob \"\(HeartbeatPlan.jobName)\" output — scheduled job, not the user. Reply in this chat if it needs Konrad.]\n\(output)" }
        let woken = [AutomationKey.woken: AutomationKind.heartbeat.rawValue, AutomationKey.display: "Heartbeat", TurnKey.restored: "added"]
        jarvis.messages = [ChatMessage(role: .user, content: "Keep an eye on the backup and the invoices today.", createdAt: now.addingTimeInterval(-7_400)),
                           ChatMessage(role: .assistant, content: "Will do. The heartbeat checks every hour and I'll only speak up if something needs you.", createdAt: now.addingTimeInterval(-7_380), turnState: .finished),
                           ChatMessage(role: .user, content: delivered("Nothing open."), createdAt: lastRun, metadata: woken.merging([AutomationKey.silent: "1"]) { $1 }),
                           ChatMessage(role: .assistant, content: "[SILENT]", createdAt: lastRun.addingTimeInterval(9), metadata: [AutomationKey.silent: "1"], turnState: .finished),
                           ChatMessage(role: .user, content: delivered("The 09:00 backup on box 2 failed: disk full."), createdAt: now.addingTimeInterval(-120), metadata: woken),
                           ChatMessage(role: .assistant, content: "One thing: the 09:00 backup on box 2 failed (disk full). Infra can clear the old snapshots if you want — say the word.", createdAt: now.addingTimeInterval(-110), turnState: .finished)]
        store.selectedBot = jarvis
        let size = NSSize(width: 1_120, height: 640)
        let chat = HStack(spacing: 0) {
            SidebarView(selection: .constant(jarvis)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: jarvis)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
        write(names[1], await png(AnyView(chat), store, size))
    }

    /// A heartbeat routine as the box lists it (P46 3).
    static func heartbeatJob(profile: String, id: String = "0000000a11ce", schedule: String, now: Date, lastRunAt: Date? = nil, paused: Bool = false) -> HermesJob {
        let stamp = { (date: Date) -> String in let formatter = ISO8601DateFormatter(); return formatter.string(from: date) }
        let next = HeartbeatPlan.nextFire(schedule, after: now, boxZone: TimeZone(secondsFromGMT: 0)!)
        return HermesJob(id: id, name: HeartbeatPlan.jobName, prompt: HeartbeatPlan.defaultPrompt, schedule: schedule, scheduleKind: "cron",
                         scheduleDisplay: schedule, enabled: !paused, state: paused ? "paused" : "scheduled", nextRunAt: next.map(stamp),
                         lastRunAt: lastRunAt.map(stamp), lastStatus: lastRunAt == nil ? nil : "ok", lastError: nil, deliver: HeartbeatPlan.delivery(profile))
    }
}

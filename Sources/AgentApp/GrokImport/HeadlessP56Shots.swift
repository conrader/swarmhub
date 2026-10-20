import AppKit
import SwiftUI

/// P56 shot of `--render-setup` (alone with `--only p56`): Settings → Heartbeat with Jarvis's routine changed on the box
/// (its cron tool moved it to 07–20) and Infra still on SwarmHub's plan. All synthetic and in memory: nothing is sent.
@MainActor enum HeadlessP56Shots {
    static let names = ["p56-settings-heartbeat-changed"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false
        let now = Date.now; store.now = { now }
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Boxes and backups", backend: .hermes, hermesProfile: "grok-infra")
        jarvis.avatarName = .robot; infra.avatarName = .octopus
        store.bots = [jarvis, infra]
        store.boxReadings[store.connection(of: jarvis)] = BoxReadings(capacity: BoxCapacityReport(cpus: 2, memTotalMB: 3_891, memAvailMB: 2_100))

        let jarvisPlan = HeartbeatPlan(), infraPlan = HeartbeatPlan(interval: 7_200, windowStart: 7 * 60, windowEnd: 19 * 60, prompt: "Disks, backups and certificates only.")
        let cron = { (plan: HeartbeatPlan, bot: Bot) in plan.cron(stagger: store.heartbeatStagger(for: bot), localOffset: store.heartbeatLocalOffset, boxOffset: 0) }
        let boxSchedule = "0 5-18 * * *"
        var jarvisJob = HeadlessP46Shots.heartbeatJob(profile: "grok-jarvis", schedule: boxSchedule, now: now, lastRunAt: now.addingTimeInterval(-1_800))
        jarvisJob.name = "jarvis-hourly-heartbeat-cet"
        var infraJob = HeadlessP46Shots.heartbeatJob(profile: "grok-infra", id: "0000000b0b00", schedule: cron(infraPlan, infra), now: now, lastRunAt: now.addingTimeInterval(-3_000))
        infraJob.prompt = infraPlan.prompt
        store.routines.update(jarvis.id) { $0.jobs = .loaded([jarvisJob]) }
        store.routines.update(infra.id) { $0.jobs = .loaded([infraJob]) }
        store.heartbeatSettings.plans[jarvis.id.uuidString] = jarvisPlan
        store.heartbeatSettings.schedules[jarvis.id.uuidString] = cron(jarvisPlan, jarvis)
        store.heartbeatSettings.plans[infra.id.uuidString] = infraPlan
        let size = NSSize(width: 760, height: 860)
        write(names[0], await png(AnyView(Form { SettingsHeartbeatPane() }.formStyle(.grouped).frame(width: size.width, height: size.height).background(AppColor.panel)), store, size))
    }
}

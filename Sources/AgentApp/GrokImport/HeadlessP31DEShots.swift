import AppKit
import SwiftUI

/// P31 D+E shots of `--render-setup`: the Overview's Sub-agents line pinned, following the bot's model and not yet
/// reported (Check), the sub-agent model sheet, and Settings → Models with the box capacity block not checked, advised,
/// and with advice after jobs waited. Synthetic store states; no turn runs.
@MainActor enum HeadlessP31DEShots {
    static let names = ["p31de-overview-subagents-pinned", "p31de-overview-subagents-same", "p31de-overview-subagents-no-report", "p31de-subagent-sheet",
                        "p31de-settings-capacity-no-report", "p31de-settings-capacity-advised", "p31de-settings-capacity-advice"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
        jarvis.canManageBots = true; jarvis.hermesBaseURL = "https://box.example.net"
        let coder = Bot(name: "Coder", persona: "You write code.", backend: .hermes, hermesProfile: "coder"); coder.hermesBaseURL = jarvis.hermesBaseURL
        store.bots = [jarvis, coder]; store.selectedBot = coder
        let target = store.connection(of: jarvis), now = Date()
        let reported = now.addingTimeInterval(-3 * 3600)
        let pinned = [BotModels(name: "grok-jarvis", model: "sample-large", provider: "sample-cloud", subModel: "sample-coder-xl", subProvider: "sample-cloud"),
                      BotModels(name: "coder", model: "sample-large", provider: "sample-cloud", subModel: "sample-coder-xl", subProvider: "sample-cloud")]
        let same = pinned.map { BotModels(name: $0.name, model: $0.model, provider: $0.provider) }
        func overview() -> AnyView {
            AnyView(VStack(alignment: .leading) { ModelRolesReadout(bot: coder, cache: store.botInfo) }.padding(16).frame(width: 460, height: 80, alignment: .topLeading).background(AppColor.panel))
        }
        for (name, rows) in [(names[0], pinned), (names[1], same), (names[2], nil)] as [(String, [BotModels]?)] {
            store.boxReadings[target] = rows.map { BoxReadings(models: $0, modelsAt: reported) }
            write(name, await png(overview(), store, NSSize(width: 460, height: 80)))
        }
        store.boxReadings[target] = BoxReadings(models: pinned, modelsAt: reported)
        let sheet = SubAgentModelSheet(request: SubAgentModelRequest(managerID: jarvis.id, profile: "coder"))
        write(names[3], await png(AnyView(sheet.background(AppColor.panel)), store, NSSize(width: 520, height: 400)))

        let job = { (hoursAgo: Double, waited: Int) in BoxCapacityReport.Job(at: now.addingTimeInterval(-hoursAgo * 3600), waited: waited, ran: 420, peakMB: 480, exit: 0) }
        let advised = BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, diskFreeMB: 17400, load1: "0.42", slots: nil,
                                        jobs: [job(30, 0), job(20, 5), job(4, 0)])
        let busy = BoxCapacityReport(cpus: 2, memTotalMB: 3891, memAvailMB: 1380, diskFreeMB: 17400, load1: "1.90", slots: 1,
                                     jobs: (0..<12).map { job(Double($0) * 10 + 1, [600, 1200, 840][$0 % 3]) })
        for (name, report) in [(names[4], nil), (names[5], advised), (names[6], busy)] as [(String, BoxCapacityReport?)] {
            store.boxReadings[target] = BoxReadings(models: pinned, modelsAt: reported, capacity: report, capacityAt: report == nil ? nil : now.addingTimeInterval(-600))
            write(name, await png(AnyView(Form { SettingsModelsPane(cache: store.botInfo) }.formStyle(.grouped)), store, NSSize(width: 760, height: 1100)))
        }
    }
}

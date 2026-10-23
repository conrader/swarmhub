import Foundation
import Testing
@testable import AgentApp

// A `--until` loop or a goal ends by a reply on the box, and only the box's alert service reads that reply and pauses the
// routine (swarm_alerts.py). The app can't confirm at quit that the service is on now, so these stay in the app whatever
// it last recorded about the box's alerts. (`handoffStore` and the fakes are in AutomationHandoffTests.swift.)

@Test(arguments: [true, false, nil] as [Bool?]) @MainActor
func anUntilLoopOrAGoalStaysInTheAppWhateverTheAppLastRecordedAboutTheBoxsAlerts(alerts: Bool?) async throws {
    // Without the service, an --until loop or a goal would keep running on the box after it ended; a recorded "on" may
    // be stale (another Mac turned alerts off since), so it is never enough.
    for automation in [ChatAutomation(loop: LoopRun(prompt: "check the build", interval: 60, timesLeft: nil, until: "the build is green", nextAt: Date())),
                       ChatAutomation(goal: GoalRun(text: "Write the release notes", maxRounds: 20, startedAt: Date(), maxDuration: 7200, codingEvidence: false))] {
        let (store, bot, server, bodies, _, _) = handoffStore(alerts: alerts)
        let kind: AutomationKind = automation.loop != nil ? .loop : .goal
        store.automations[bot.id] = automation
        #expect(store.handoffPlans(now: Date()).isEmpty)
        store.handOffForQuit(budget: 5)
        store.handOffForQuit(budget: 5)
        #expect(bodies.all.isEmpty && server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil, "\(kind) stays in the app")
        #expect(bot.messages.filter { $0.content == HandoffCopy.staysHere(kind) }.count == 1, "said once, not at every quit")
    }
    // A loop that only ends by its count or a stop needs nothing on the box to end it: it still goes.
    let (store, bot, _, bodies, _, _) = handoffStore(alerts: alerts)
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "ping", interval: 600, timesLeft: 3, until: nil, nextAt: Date()))
    store.handOffForQuit(budget: 5)
    #expect(bodies.all.count == 1 && store.automations[bot.id]?.boxHandoff?.kind == .loop)
}

@Test @MainActor func aMacWhoseAlertsRecordIsStaleNeverHandsOffAnUntilLoopAndARefreshCorrectsTheRecord() async throws {
    // Mac A turned alerts on; Mac B turned them off later. A still records them as on.
    let (store, bot, server, bodies, _, _) = handoffStore(alerts: true)
    let target = store.connection(of: bot)
    var boxEnabled = false
    store.alertsControl = { _, arguments in alertsPanelJSON(action: arguments[2], configured: true, enabled: boxEnabled, running: boxEnabled) }
    #expect(store.alertServers == [target])
    store.automations[bot.id] = ChatAutomation(loop: LoopRun(prompt: "check the build", interval: 60, timesLeft: nil, until: "the build is green", nextAt: Date()))
    store.handOffForQuit(budget: 5)
    #expect(bodies.all.isEmpty && server.jobIDs.isEmpty && store.automations[bot.id]?.boxHandoff == nil, "a stale record hands nothing off")
    await store.refreshAlerts(on: target)
    #expect(store.alertServers.isEmpty && store.defaults.object(forKey: "alerts.on." + target) as? Bool == false, "refresh records the box's answer")
    boxEnabled = true
    await store.refreshAlerts(on: target)
    #expect(store.alertServers == [target])
}

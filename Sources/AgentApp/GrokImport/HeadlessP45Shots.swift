import AppKit
import SwiftUI

/// P45 shots of `--render-setup` (alone with `--only p45`): the composer's `/` menu, the `@` picker in a 1:1 chat, a chat
/// with a heartbeat in its header, a chat with the goal chip mid-run, and the "Goal reached" card. All synthetic and in
/// memory: nothing is sent or read from a server.
@MainActor enum HeadlessP45Shots {
    static let names = ["p45-slash-menu", "p45-mention-picker", "p45-heartbeat-header", "p45-goal-running", "p45-goal-reached"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false
        let now = Date.now; store.now = { now }
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Boxes and backups", backend: .hermes, hermesProfile: "grok-infra")
        let reactor = Bot(name: "Reactor", title: "Daily ops", backend: .hermes, hermesProfile: "grok-reactor")
        jarvis.avatarName = .robot; infra.avatarName = .octopus; reactor.avatarName = .planet
        store.bots = [jarvis, infra, reactor]

        // 1–2: the composer with the `/` menu open, and with `@In` typed in Jarvis's 1:1 chat.
        let composerSize = NSSize(width: 760, height: 420)
        func composer(_ text: String, mentions: [String] = []) -> some View {
            VStack { Spacer(); ComposerView(text: .constant(text), attachments: .constant([]), isStreaming: false, send: {}, stop: {}, mentionNames: mentions, slashCommands: SlashCommand.menu) }
                .frame(width: composerSize.width, height: composerSize.height).background(AppColor.chat)
        }
        write(names[0], await png(AnyView(composer("/")), store, composerSize))
        write(names[1], await png(AnyView(composer("@In", mentions: store.mentionTargets(for: jarvis).map(\.name))), store, composerSize))

        // 3: Jarvis with an hourly heartbeat 08–23; the last check-in was [SILENT], so it is hidden.
        jarvis.messages = [ChatMessage(role: .user, content: "Keep an eye on the backup and the invoices today.", createdAt: now.addingTimeInterval(-5_400)),
                           ChatMessage(role: .assistant, content: "Will do. I'll check in every hour and only speak up if something needs you.", createdAt: now.addingTimeInterval(-5_380), turnState: .finished),
                           ChatMessage(role: .user, content: HeartbeatPlan.defaultPrompt, createdAt: now.addingTimeInterval(-1_800), metadata: [AutomationKey.woken: "heartbeat", AutomationKey.display: "Heartbeat", AutomationKey.silent: "1"]),
                           ChatMessage(role: .assistant, content: "[SILENT]", createdAt: now.addingTimeInterval(-1_790), metadata: [AutomationKey.silent: "1"], turnState: .finished),
                           ChatMessage(role: .user, content: HeartbeatPlan.defaultPrompt, createdAt: now.addingTimeInterval(-60), metadata: [AutomationKey.woken: "heartbeat", AutomationKey.display: "Heartbeat"]),
                           ChatMessage(role: .assistant, content: "One thing: the 09:00 backup on box 2 failed (disk full). Infra can clear the old snapshots if you want.", createdAt: now.addingTimeInterval(-50), turnState: .finished)]
        // P46: the heartbeat is Jarvis's routine now; the strip reads it from the routines cache.
        store.routines.update(jarvis.id) { $0.jobs = .loaded([HeadlessP46Shots.heartbeatJob(profile: "grok-jarvis", schedule: HeartbeatPlan().cron(stagger: store.heartbeatStagger(for: jarvis), localOffset: store.heartbeatLocalOffset, boxOffset: 0), now: now)]) }
        store.heartbeatSettings.plans[jarvis.id.uuidString] = HeartbeatPlan()
        store.selectedBot = jarvis
        let size = NSSize(width: 1_120, height: 640)
        write(names[2], await png(AnyView(chat(jarvis, size: size)), store, size))

        // 4: Reactor working on a goal, round 3 of 20, a continuation streaming.
        let goal = GoalRun(text: "Reconcile October's incoming payments with the ledger", round: 3, maxRounds: 20, startedAt: now.addingTimeInterval(-1_500), maxDuration: 7_200, awaitingReply: true,
                           lastSummary: "Matched 41 of 58 payments; 17 left, most from the PayU batch.")
        store.automations[reactor.id] = ChatAutomation(goal: goal)
        let first = GoalRun(text: goal.text, maxRounds: 20, startedAt: goal.startedAt, maxDuration: 7_200)
        let streaming = ChatMessage(role: .assistant, content: "Picking up the PayU batch: 17 payments, matching them by amount and date against the ledger…", createdAt: now.addingTimeInterval(-20), isStreaming: true, turnState: .incomplete)
        reactor.messages = [ChatMessage(role: .user, content: GoalProtocol.firstTurn(first), createdAt: now.addingTimeInterval(-1_500), metadata: [AutomationKey.display: "Goal: \(goal.text)"]),
                            ChatMessage(role: .assistant, content: "Starting with the bank export: 58 incoming payments in October. Matched 23 so far.", createdAt: now.addingTimeInterval(-1_440), turnState: .finished),
                            ChatMessage(role: .user, content: GoalProtocol.continuation(first), createdAt: now.addingTimeInterval(-900), metadata: [AutomationKey.woken: "goal", AutomationKey.display: "Continue toward the goal"]),
                            ChatMessage(role: .assistant, content: "Matched 41 of 58 payments; 17 left, most from the PayU batch.", createdAt: now.addingTimeInterval(-850), turnState: .finished),
                            ChatMessage(role: .user, content: GoalProtocol.continuation(first), createdAt: now.addingTimeInterval(-30), metadata: [AutomationKey.woken: "goal", AutomationKey.display: "Continue toward the goal"]),
                            streaming]
        store.selectedBot = reactor
        write(names[3], await png(AnyView(chat(reactor, size: size)), store, size))

        // 5: the goal reached: its card with the summary, the chip gone.
        streaming.isStreaming = false; streaming.turnState = .finished
        streaming.content = "All 58 payments are matched; three PayU fees were booked as bank costs.\n```swarmhub\n{\"op\":\"goal\",\"status\":\"done\",\"summary\":\"All 58 October payments reconciled; 3 PayU fees booked as bank costs.\"}\n```"
        var done = goal; done.state = .done; done.awaitingReply = false
        store.automations[reactor.id] = ChatAutomation(goal: done)
        reactor.messages.append(ChatMessage(role: .system, content: "Goal reached", presentation: .automation,
                                            metadata: [AutomationKey.card: "goalDone", AutomationKey.detail: "All 58 October payments reconciled; 3 PayU fees booked as bank costs."]))
        // Taller, so the card shows whole below the transcript.
        let tall = NSSize(width: size.width, height: 800)
        write(names[4], await png(AnyView(chat(reactor, size: tall)), store, tall))
    }

    private static func chat(_ bot: Bot, size: NSSize) -> some View {
        HStack(spacing: 0) {
            SidebarView(selection: .constant(bot)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: bot)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
    }
}

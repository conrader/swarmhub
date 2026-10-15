import AppKit
import SwiftUI

/// P43 shots of `--render-setup` (alone with `--only p43`): a Swarmhub-style reply drawn in the order it happened (opening
/// text, its three steps, the answer), a routine row Running… after Run now, and the finished card in the bot's chat
/// with its Open result sheet. All synthetic and in memory: nothing is sent or read from a server.
@MainActor enum HeadlessP43Shots {
    static let names = ["p43-reply-in-order", "p43-reply-in-order-open", "p43-routine-running", "p43-routine-card", "p43-routine-open-result"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false
        let now = Date.now
        let swarmhub = Bot(name: "Swarmhub", title: "Repo onboarding", backend: .hermes, hermesProfile: "swarmhub")
        let reactor = Bot(name: "Reactor", title: "Daily ops", backend: .hermes, hermesProfile: "reactor")
        swarmhub.avatarName = .robot; reactor.avatarName = .planet
        store.bots = [swarmhub, reactor]

        // 1. Text → steps → answer, as the live reply of 2026-10-15 streamed.
        let opening = "I'll start with a read-only onboarding audit: read the skill, look at the repo, then write the notes."
        let answer = "Started. I audited the live README and the open issues, and wrote the onboarding notes to `docs/ONBOARDING.md`.\n\nNothing was pushed or published."
        let ask = ChatMessage(role: .user, content: "Onboard the swarmhub repo for a new contributor.", createdAt: now.addingTimeInterval(-75))
        let reply = ChatMessage(role: .assistant, content: opening + answer, createdAt: now.addingTimeInterval(-72), turnState: .finished)
        var steps = ToolActivity(); let offset = opening.utf16.count
        for (index, (name, preview)) in [("skill_view", "swarmhub-onboarding"), ("terminal", "git -C ~/swarmhub log --oneline -20"), ("write_file", "docs/ONBOARDING.md")].enumerated() {
            let start = now.addingTimeInterval(-70 + Double(index) * 14)
            steps.apply(ToolEvent(phase: .started, name: name, preview: preview, callID: "c\(index)"), at: start, textOffset: offset)
            steps.apply(ToolEvent(phase: .completed, name: name, callID: "c\(index)"), at: start.addingTimeInterval(9))
        }
        steps.finish(at: now.addingTimeInterval(-20)); reply.activity = steps
        swarmhub.messages = [ask, reply]
        store.selectedBot = swarmhub
        let size = NSSize(width: 1_120, height: 640)
        write(names[0], await png(AnyView(chat(swarmhub, size: size)), store, size))
        var open = MessageView(message: reply); open.stepsExpanded = true
        let openSize = NSSize(width: 760, height: 420)
        write(names[1], await png(AnyView(VStack { open; Spacer() }.frame(width: openSize.width, height: openSize.height, alignment: .topLeading).background(AppColor.chat)), store, openSize))

        // 2. Run now was clicked: Running… at once, the button off.
        let audit = HermesJob(id: "1c33e2cfacf1", name: "Onboarding audit", prompt: "Audit the repo's onboarding docs", schedule: "0 9 * * 1-5", scheduleKind: "cron",
                              scheduleDisplay: "0 9 * * 1-5", enabled: true, state: "scheduled", nextRunAt: nil, lastRunAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400)),
                              lastStatus: "ok", lastError: nil, manualRunAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-3)))
        let digest = HermesJob(id: "0123456789ab", name: "Daily digest", prompt: "Summarise yesterday", schedule: "30 7 * * *", scheduleKind: "cron",
                               scheduleDisplay: "30 7 * * *", enabled: true, state: "scheduled", nextRunAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(36_000)),
                               lastRunAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-50_000)), lastStatus: "ok", lastError: nil)
        store.routines.update(reactor.id) { $0.jobs = .loaded([audit, digest]); $0.running[audit.id] = now.addingTimeInterval(-3) }
        let panel = NSSize(width: 420, height: 360)
        let routines = RoutinesView(bot: reactor, cache: store.routines).padding(16).frame(width: panel.width, height: panel.height, alignment: .topLeading).background(AppColor.panel)
        write(names[2], await png(AnyView(routines), store, panel))

        // 3. The run's card in Reactor's chat; 4. Open result.
        var finished = audit; finished.lastRunAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30)); finished.manualRunAt = nil
        let output = "Onboarding audit — swarmhub\n\nREADME: current; the setup section matches 0.5.4.\nCONTRIBUTING: missing the test command (`swift test`).\nOpen issues tagged good-first-issue: 4, two without a description.\n\n"
            + "Suggested next steps:\n1. Add the test command to CONTRIBUTING.\n2. Describe issues #212 and #219.\n3. Link docs/ONBOARDING.md from the README.\n\n"
            + String(repeating: "Checked file by file: docs, scripts, Sources, Tests — no stale paths found. ", count: 6)
        let card = AppStore.routineCard(job: finished, result: .init(sessionID: "cron_1c33e2cfacf1_20261015_200403", text: output), lookupError: nil)
        reactor.messages = [ChatMessage(role: .user, content: "Run the onboarding audit now.", createdAt: now.addingTimeInterval(-200)),
                            ChatMessage(role: .assistant, content: "Started it — the result will show here when the run ends.", createdAt: now.addingTimeInterval(-190), turnState: .finished), card]
        store.selectedBot = reactor
        write(names[3], await png(AnyView(chat(reactor, size: size)), store, size))
        let sheet = RoutineResultSheet(message: card, output: .loaded(output)).background(AppColor.panel)
        write(names[4], await png(AnyView(sheet), store, NSSize(width: 560, height: 480)))
    }

    private static func chat(_ bot: Bot, size: NSSize) -> some View {
        HStack(spacing: 0) {
            SidebarView(selection: .constant(bot)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: bot)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
    }
}

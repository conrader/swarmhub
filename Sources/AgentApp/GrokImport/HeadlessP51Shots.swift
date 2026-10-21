import AppKit
import SwiftUI

/// P51 shots of `--render-setup` (alone with `--only p51`): a chat like Jarvis's with its technical rows folded (an app
/// lookup and execute, a skills_installed reply, a heartbeat that loaded a skill, a bot-to-bot pair, Hermes's own async
/// delegation note), and the same chat with one of each unfolded. All synthetic and in memory: nothing is sent or saved.
@MainActor enum HeadlessP51Shots {
    static let names = ["p51-folded", "p51-unfolded"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false; store.botWork.autoStart = false
        let now = Date.now; store.now = { now }
        let jarvis = Bot(name: "Jarvis", title: "Coordinator", description: "Runs the team", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Servers", description: "Keeps the boxes up", backend: .hermes, hermesProfile: "grok-infra")
        jarvis.avatarName = .robot; infra.avatarName = .octopus
        store.bots = [jarvis, infra]
        jarvis.messages = transcript(now: now)
        jarvis.messages.forEach { $0.metadata.merge(["box": "3761", "restored": "added"]) { old, _ in old } }
        let folded = NSSize(width: 1_120, height: 960), tall = NSSize(width: 1_120, height: 2_000)
        func chat(_ size: NSSize) -> AnyView {
            AnyView(HStack(spacing: 0) {
                SidebarView(selection: .constant(jarvis)).frame(width: SidebarMetrics.width.ideal)
                Divider()
                ChatView(bot: jarvis)
            }.frame(width: size.width, height: size.height).background(AppColor.chat))
        }
        store.selectedBot = jarvis
        write(names[0], await png(chat(folded), store, folded))

        // One of each unfolded (taller, so all of them show): the app lookup, the swarmhub block, the skill text, the
        // bot-to-bot message, the delegation note.
        let rows = jarvis.messages
        for index in [1, 6, 8, 12] { store.technicalFolds.unfold(TechnicalFolds.key(rows[index].id)) }
        store.technicalFolds.unfold(TechnicalFolds.key(rows[5].id, "fence0.0"))
        write(names[1], await png(chat(tall), store, tall))
    }

    private static let marker = "[[SWARMHUB_APP_REQUEST_3F2A9C61-58D4-4B7E-A0C2-7E19D84B6A15]]"

    private static func transcript(now: Date) -> [ChatMessage] {
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        let tools = #"{"tools":[{"app":"github","slug":"GITHUB_GET_THE_AUTHENTICATED_USER","description":"Get the authenticated user","arguments_schema":{"properties":{},"title":"GetTheAuthenticatedUserRequest","type":"object"}}],"accounts":{"github":["GitHub · octo-konrad"]}}"#
        let user = #"{"data":{"login":"octo-konrad","public_repos":12},"successful":true}"#
        let next = "\nContinue the original task. Use the app request format only if another app call is needed."
        let skill = """
        [IMPORTANT: The user has invoked the "agent-background-operations" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]

        ---
        name: agent-background-operations
        description: How to run hourly checks without waking Konrad.
        ---
        # Background operations
        1. Read the queue and the last report.
        2. Act only on items marked urgent.
        3. Reply [SILENT] when nothing needs Konrad.
        """
        return [
            ChatMessage(role: .user, content: "Check which GitHub account you are connected to.", createdAt: at(-42)),
            ChatMessage(role: .assistant, content: marker + "\n{\"action\":\"search\",\"query\":\"Read the authenticated GitHub user\"}", createdAt: at(-41.9)),
            ChatMessage(role: .user, content: ConnectedAppsChat.resultPrefix + tools + next, createdAt: at(-41.8)),
            ChatMessage(role: .assistant, content: marker + "\n{\"action\":\"execute\",\"tool\":\"GITHUB_GET_THE_AUTHENTICATED_USER\",\"arguments\":{}}", createdAt: at(-41.7)),
            ChatMessage(role: .user, content: ConnectedAppsChat.resultPrefix + user + next, createdAt: at(-41.5)),
            ChatMessage(role: .assistant, content: "Connected as **octo-konrad** (12 public repositories). I also refreshed my SwarmHub skills.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"swarmhub-coding\",\"version\":\"1.1.1\",\"variant\":\"claude,codex,hermes\"},{\"name\":\"swarmhub-messages\",\"version\":\"1.1.0\"}]}\n```",
                        createdAt: at(-41), turnState: .finished),
            ChatMessage(role: .user, content: skill, createdAt: at(-30), metadata: [AutomationKey.woken: AutomationKind.heartbeat.rawValue]),
            ChatMessage(role: .assistant, content: "Hourly check: the backup on box 2 finished at 08:58; nothing else is waiting.", createdAt: at(-29.5), turnState: .finished),
            ChatMessage(role: .assistant, content: "Infra wrote to Jarvis", createdAt: at(-12), presentation: .botMessage,
                        metadata: [BotWorkKey.origin: "bot:grok-infra", BotMessageKey.from: "grok-infra", BotMessageKey.to: "grok-jarvis",
                                   BotWorkKey.request: "Disk on box 2 is at 91%. Can I delete build caches older than 7 days?\nThey take about 40 GB.",
                                   BotWorkKey.reply: "Yes, delete caches older than 7 days; keep this week's."]),
            ChatMessage(role: .assistant, content: "Infra replied to Jarvis", createdAt: at(-4), presentation: .botMessage,
                        metadata: [BotWorkKey.origin: "reply:grok-infra", BotMessageKey.from: "grok-infra", BotMessageKey.to: "grok-jarvis",
                                   BotWorkKey.request: "Done: 41 GB freed, disk at 63%.", BotWorkKey.reply: "Thanks, noted in the hourly report."]),
            ChatMessage(role: .user, content: "Anything else today?", createdAt: at(-2)),
            ChatMessage(role: .assistant, content: "No: the disk is fixed and GitHub works. Next check at 10:00.", createdAt: at(-1.8), turnState: .finished),
            ChatMessage(role: .user, content: """
            [ASYNC DELEGATION BATCH COMPLETE — deleg_b801d015]
            A background fan-out unit you dispatched earlier — 4 subagent(s) — has finished; its consolidated results are below.

            [1/4] Check the backups on box 1 and box 2: completed (58s)
            Both nightly backups finished; box 2 at 08:58.
            """, createdAt: at(-1), metadata: [HermesDisplayKey.kind: "async_delegation_complete"]),
            ChatMessage(role: .assistant, content: "All four checks are back: backups, disk and certificates are fine.", createdAt: at(-0.5), turnState: .finished)
        ]
    }
}

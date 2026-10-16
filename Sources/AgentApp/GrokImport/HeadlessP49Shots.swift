import AppKit
import SwiftUI

/// P49 shots of `--render-setup` (alone with `--only p49`): a new bot's chat with its collapsed "Orientation" row, a reply
/// like the SwarmHub bot's of 2026-10-16 and Jarvis's confirmation arriving as a P42 bot message; and Settings → Advanced →
/// Orientation with the switch, the coordinator picker and the quiet hours. All synthetic and in memory: nothing is sent.
@MainActor enum HeadlessP49Shots {
    static let names = ["p49-new-bot-orientation", "p49-settings-orientation"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.routines.autoLoad = false; store.botWork.autoStart = false
        let now = Date.now; store.now = { now }
        store.heartbeatTimeZone = TimeZone(identifier: "Europe/Warsaw") ?? .current
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", description: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Servers and deploys", backend: .hermes, hermesProfile: "grok-infra")
        let swarmhub = Bot(name: "Swarmhub", title: "Hermes profile", description: "Builds and ships SwarmHub", backend: .hermes, hermesProfile: "swarmhub")
        jarvis.avatarName = .robot; infra.avatarName = .octopus; jarvis.canManageBots = true
        store.bots = [swarmhub, jarvis, infra]

        // 1. Jarvis created Swarmhub a minute ago; SwarmHub sent the orientation (collapsed) and the bot answered.
        let prompt = store.orientationPrompt(for: swarmhub)
        swarmhub.orientedAt = now.addingTimeInterval(-55)
        swarmhub.messages = [
            ChatMessage(role: .user, content: prompt, createdAt: now.addingTimeInterval(-55),
                        metadata: [AutomationKey.display: OrientationCopy.display, AutomationKey.orientation: "1"]),
            ChatMessage(role: .assistant, content: reply, createdAt: now.addingTimeInterval(-40), turnState: .finished),
            ChatMessage(role: .system, content: BotMessageCopy.arrival(from: "Jarvis", to: swarmhub.name), createdAt: now.addingTimeInterval(-20), presentation: .botMessage,
                        metadata: [BotMessageKey.from: "grok-jarvis", BotMessageKey.to: "swarmhub", BotMessageKey.session: "p49-render"]),
            ChatMessage(role: .assistant, content: "Jarvis has confirmed the assignment. The survey is running; I'll report to Jarvis when it's done, and to you after 08:00 Warsaw.",
                        createdAt: now.addingTimeInterval(-10), turnState: .finished)
        ]
        store.selectedBot = swarmhub
        let size = NSSize(width: 1_120, height: 720)
        let chat = HStack(spacing: 0) {
            SidebarView(selection: .constant(swarmhub)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: swarmhub)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
        write(names[0], await png(AnyView(chat), store, size))

        // 2. Settings → Advanced → Orientation: on, Default (Jarvis), quiet hours 22:00–08:00.
        let pane = NSSize(width: 760, height: 560)
        let form = Form { SettingsOrientationPane() }.formStyle(.grouped).frame(width: pane.width, height: pane.height).background(AppColor.panel)
        write(names[1], await png(AnyView(form), store, pane))
    }

    static let reply = """
        Hi Konrad, Swarmhub here. I'll look after conrader/swarmhub: what's built, what's missing, and what to do next.

        I'm starting a read-only survey of conrader/swarmhub (code, README, issues, PRs, what's built and what's missing). \
        I've told Jarvis about it and asked for confirmation.

        I'll report to Jarvis when it's done, and to you too after 08:00 Warsaw, with a short plan and the next queued tasks. \
        If the repo is private and cloning fails, I'll flag it and say what you need to do.
        """
}

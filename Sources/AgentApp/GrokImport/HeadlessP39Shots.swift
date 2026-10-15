import AppKit
import SwiftUI

/// P39 shots of `--render-setup` (alone with `--only p39`): one chat streaming while the sidebar shows two working bots
/// (the manager writing SwarmHub's instructions in its own chat), and a send over the turn limit waiting with its line.
/// All synthetic and in memory: the turns are slots without tasks, nothing is sent.
@MainActor enum HeadlessP39Shots {
    static let names = ["p39-two-bots-working", "p39-turn-limit-wait"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let now = Date.now
        let jarvis = Bot(name: "Jarvis", title: "Manager", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
        let cfo = Bot(name: "Cfo", title: "Budgets and invoices", backend: .hermes, hermesProfile: "cfo")
        let research = Bot(name: "Research", title: "Sources and facts", backend: .hermes, hermesProfile: "research")
        for (index, bot) in [jarvis, cfo, research].enumerated() { bot.avatarName = BotAvatarName.allCases[min(index * 3, BotAvatarName.allCases.count - 1)] }
        research.messages = [ChatMessage(role: .assistant, content: "Contractor day rates are up 4% year on year.", createdAt: now.addingTimeInterval(-3_600))]
        store.bots = [jarvis, cfo, research]

        // The manager installs SwarmHub's instructions in its chat while Cfo answers in the open chat.
        let install = ChatMessage(role: .user, content: "Install SwarmHub’s instructions for Cfo.", createdAt: now.addingTimeInterval(-40))
        let writing = ChatMessage(role: .assistant, content: "", createdAt: now.addingTimeInterval(-38), isStreaming: true, turnState: .incomplete)
        var steps = ToolActivity(); steps.apply(ToolEvent(phase: .started, name: "terminal", preview: "mkdir -p ~/.hermes/profiles/cfo/skills/swarmhub"), at: now.addingTimeInterval(-30))
        writing.activity = steps
        jarvis.messages = [install, writing]
        let question = ChatMessage(role: .user, content: "Which October invoices are still unpaid?", createdAt: now.addingTimeInterval(-20))
        let answer = ChatMessage(role: .assistant, content: "Three are open so far:\n\n- Northwind — 2,400 EUR, due 31 Oct\n- Contoso — 1,150 EUR, due 4 Nov\n",
                                 createdAt: now.addingTimeInterval(-18), isStreaming: true, turnState: .incomplete)
        answer.lastTextAt = now
        cfo.messages = [question, answer]
        store.beginTurn(in: jarvis, bot: jarvis, assistant: writing)
        store.beginTurn(in: cfo, bot: cfo, assistant: answer)
        store.selectedBot = cfo
        let size = NSSize(width: 1_120, height: 640)
        let window = HStack(spacing: 0) {
            SidebarView(selection: .constant(cfo)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: cfo)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
        write(names[0], await png(AnyView(window), store, size))

        // A seventh send waits as Research's next message until a reply ends.
        let waiting = ChatMessage(role: .user, content: "Find the two agencies' current day rates.", createdAt: now, metadata: [TurnWaitCopy.key: "waiting"])
        research.messages.append(contentsOf: [waiting, ChatMessage(role: .system, content: "Waiting: 6 replies are already running.", createdAt: now, metadata: [TurnWaitCopy.key: "line"])])
        store.selectedBot = research
        let chat = HStack(spacing: 0) {
            SidebarView(selection: .constant(research)).frame(width: SidebarMetrics.width.ideal)
            Divider()
            ChatView(bot: research)
        }.frame(width: size.width, height: size.height).background(AppColor.chat)
        write(names[1], await png(AnyView(chat), store, size))
        store.runningTurns = [:]
    }
}

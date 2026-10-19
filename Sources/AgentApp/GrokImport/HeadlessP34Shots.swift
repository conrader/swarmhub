import AppKit
import SwiftUI

/// P34 shots of `--render-setup`: Jarvis's reply with its bot-msg steps open (the "→ Infra" chip on the step and under
/// the reply), the Jarvis → Infra thread sheet, the arrival line in Infra's chat, Infra's Activity tab with "Bot
/// messages", and the quick switcher listing threads. Throwaway in-memory store with a mock backend; no network, no
/// Keychain.
@MainActor enum HeadlessP34Shots {
    static let names = ["p34-step-chip", "p34-thread-sheet", "p34-arrival-line", "p34-activity-bot-messages", "p34-quick-switcher-threads"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .hermes, hermesProfile: "grok-infra")
        let coder = Bot(name: "Coder", title: "Writes and fixes code", backend: .hermes, hermesProfile: "coder")
        jarvis.avatarName = .allCases[0]; infra.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]; coder.avatarName = .allCases[min(6, BotAvatarName.allCases.count - 1)]
        let now = Date.now, start = now.addingTimeInterval(-420)
        let script = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg --priority --from grok-jarvis"
        let reply = ChatMessage(role: .assistant, content: "Infra says **/data is at 62 %** and the nightly backup finished at 03:12. I asked Coder to look at the slow export; it will answer in its thread.",
                                createdAt: start, turnState: .finished)
        var activity = ToolActivity()
        activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "notes/servers.md", callID: "1"), at: start)
        activity.apply(ToolEvent(phase: .completed, name: "read_file", callID: "1"), at: start.addingTimeInterval(1))
        activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "bot-msg --to grok-infra", callID: "2",
                                 command: "\(script) --to grok-infra -- \"How full is /data, and did last night's backup finish?\""), at: start.addingTimeInterval(2))
        activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "2", result: #"{"output":"/data is at 62 %. The nightly backup finished at 03:12, 41 GB, no errors."}"#), at: start.addingTimeInterval(9))
        activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "bot-msg --to coder --no-wait", callID: "3",
                                 command: "\(script) --to coder --no-wait -- \"The CSV export takes 40 s; can you find why?\""), at: start.addingTimeInterval(10))
        activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "3", result: #"{"output":"swarmhub-from-grok-jarvis"}"#), at: start.addingTimeInterval(11))
        activity.finish(at: start.addingTimeInterval(14)); reply.activity = activity
        jarvis.messages = [ChatMessage(role: .user, content: "check the servers with infra, and ask coder about the slow export", createdAt: start.addingTimeInterval(-5)), reply]

        let key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
        store.botMessages.loaded[key] = [
            BotThreadLine(id: "1", author: "grok-jarvis", text: "Is the 2 a.m. backup job still on the old disk?", date: now.addingTimeInterval(-86_400)),
            BotThreadLine(id: "2", author: "grok-infra", text: "Yes, until Friday; then it moves to /data.", date: now.addingTimeInterval(-86_390)),
            BotThreadLine(id: "3", author: "grok-jarvis", text: "How full is /data, and did last night's backup finish?", date: start.addingTimeInterval(2)),
            BotThreadLine(id: "4", author: "grok-infra", text: "/data is at 62 %. The nightly backup finished at 03:12, 41 GB, no errors.", date: start.addingTimeInterval(9))
        ]
        infra.messages = [ChatMessage(role: .user, content: "what's the uptime on box 2?", createdAt: now.addingTimeInterval(-3_600)),
                          ChatMessage(role: .assistant, content: "Box 2 has been up 41 days; load is 0.4.", createdAt: now.addingTimeInterval(-3_590), turnState: .finished)]
        store.bots = [jarvis, infra, coder]
        store.applyBotThreadRows([], recipient: infra)
        store.applyBotThreadRows([BotThreadRow(sessionID: key.sessionID, sender: "grok-jarvis", mark: "4", updatedAt: start.addingTimeInterval(9),
                                               preview: "How full is /data, and did last night's backup finish?")], recipient: infra)
        store.applyBotThreadRows([], recipient: coder)
        store.applyBotThreadRows([BotThreadRow(sessionID: key.sessionID, sender: "grok-jarvis", mark: "1", updatedAt: start.addingTimeInterval(11),
                                               preview: "The CSV export takes 40 s; can you find why?")], recipient: coder)

        store.selectedBot = jarvis
        var message = MessageView(message: reply); message.stepsExpanded = true
        let row = VStack(alignment: .leading, spacing: 0) { message; Spacer() }
        write(names[0], await png(AnyView(row.frame(width: 820, height: 420, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 420)))
        write(names[1], await png(AnyView(BotThreadSheet(center: store.botMessages, key: key)), store, NSSize(width: 520, height: 560)))
        store.selectedBot = infra
        write(names[2], await png(AnyView(ChatView(bot: infra)), store, NSSize(width: 820, height: 520)))
        store.infoTab = .activity
        write(names[3], await png(AnyView(InfoPanel(bot: infra)), store, NSSize(width: 360, height: 700)))
        write(names[4], await png(AnyView(CommandPaletteView(selectCommand: { _ in }, openSetup: {})), store, NSSize(width: 480, height: 380)))
    }
}

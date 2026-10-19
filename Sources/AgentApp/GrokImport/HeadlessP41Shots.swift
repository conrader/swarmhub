import AppKit
import SwiftUI

/// P41 shots of `--render-setup` (alone with `--only p41`): Jarvis's bot-msg step with "Infra replied" and the reply
/// open, the sidebar while Jarvis waits on Infra ("Working… · message from Jarvis"), Infra's chat with that header and
/// the arrival line, and the arrival above a side thread of Infra's chat. Throwaway in-memory store with a mock backend;
/// no network, no Keychain.
@MainActor enum HeadlessP41Shots {
    static let names = ["p41-chip-infra-replied", "p41-sidebar-infra-working", "p41-infra-chat-arrival", "p41-infra-thread-arrival"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .hermes, hermesProfile: "grok-infra")
        let coder = Bot(name: "Coder", title: "Writes and fixes code", backend: .hermes, hermesProfile: "coder")
        jarvis.avatarName = .allCases[0]; infra.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]; coder.avatarName = .allCases[min(6, BotAvatarName.allCases.count - 1)]
        let now = Date.now, start = now.addingTimeInterval(-200)
        let command = "/home/hermes/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg --priority --from grok-jarvis --to grok-infra --wait 300 -- 'Is the backup disk on box 2 healthy, and did last night's run finish?'"
        let answer = "Backup disk on box 2 is healthy (SMART ok, 41 % used). Last night's run finished at 03:12: 41 GB, no errors. I also rotated the old snapshots."

        // 1: the finished reply, its bot-msg step with Infra's answer open.
        let done = ChatMessage(role: .assistant, content: "Infra checked box 2: the backup disk is healthy and last night's run finished at 03:12 without errors.",
                               createdAt: start, turnState: .finished)
        var finished = ToolActivity()
        finished.apply(ToolEvent(phase: .started, name: "read_file", preview: "notes/servers.md", callID: "1"), at: start)
        finished.apply(ToolEvent(phase: .completed, name: "read_file", callID: "1"), at: start.addingTimeInterval(1))
        finished.apply(ToolEvent(phase: .started, name: "terminal", preview: ToolEvent.preview(command), callID: "2", command: command), at: start.addingTimeInterval(2))
        finished.apply(ToolEvent(phase: .completed, name: "terminal", callID: "2", result: #"{"output":"\#(answer)","exit_code":0}"#), at: start.addingTimeInterval(152))
        finished.finish(at: start.addingTimeInterval(160)); done.activity = finished
        jarvis.messages = [ChatMessage(role: .user, content: "ask infra whether the backup on box 2 is fine", createdAt: start.addingTimeInterval(-5)), done]
        infra.messages = [ChatMessage(role: .user, content: "what's the uptime on box 2?", createdAt: now.addingTimeInterval(-3_600)),
                          ChatMessage(role: .assistant, content: "Box 2 has been up 41 days; load is 0.4.", createdAt: now.addingTimeInterval(-3_590), turnState: .finished)]
        coder.messages = [ChatMessage(role: .assistant, content: "The export fix is merged.", createdAt: now.addingTimeInterval(-7_200), turnState: .finished)]
        store.bots = [jarvis, infra, coder]; store.selectedBot = jarvis
        var message = MessageView(message: done); message.stepsExpanded = true; message.botRepliesExpanded = true
        let row = VStack(alignment: .leading, spacing: 0) { message; Spacer() }
        write(names[0], await png(AnyView(row.frame(width: 820, height: 420, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 420)))

        // 2: a new turn of Jarvis waiting on bot-msg; Infra works for it.
        let live = ChatMessage(role: .assistant, content: "", createdAt: now.addingTimeInterval(-40), isStreaming: true)
        var running = ToolActivity()
        running.apply(ToolEvent(phase: .started, name: "terminal", preview: ToolEvent.preview(command), callID: "3", command: command), at: now.addingTimeInterval(-38))
        live.activity = running
        jarvis.messages.append(contentsOf: [ChatMessage(role: .user, content: "and ask infra about the disk again", createdAt: now.addingTimeInterval(-41)), live])
        store.beginTurn(in: jarvis, bot: jarvis, assistant: live)
        let sidebar = VStack(spacing: 0) {
            ForEach([jarvis, infra, coder]) { bot in
                BotRow(bot: bot, drafts: store.drafts, selected: bot.id == infra.id, botToDelete: .constant(nil))
            }
            Spacer()
        }.padding(SidebarMetrics.listInset).frame(width: 300, height: 260).background(AppColor.sidebar).environment(\.activityNow, now)
        write(names[1], await png(AnyView(sidebar), store, NSSize(width: 300, height: 260)))

        // 3: Infra's chat: the header while it works for Jarvis, and the arrival line.
        let key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
        store.botMessages.loaded[key] = [BotThreadLine(id: "1", author: "grok-jarvis", text: "Is the backup disk on box 2 healthy, and did last night's run finish?", date: start.addingTimeInterval(2)),
                                         BotThreadLine(id: "2", author: "grok-infra", text: answer, date: start.addingTimeInterval(150))]
        store.applyBotThreadRows([], recipient: infra)
        store.applyBotThreadRows([BotThreadRow(sessionID: key.sessionID, sender: "grok-jarvis", mark: "44", updatedAt: start.addingTimeInterval(150), preview: nil)], recipient: infra)
        store.open(infra, remember: false)
        write(names[2], await png(AnyView(ChatView(bot: infra)), store, NSSize(width: 820, height: 520)))

        // 4: the same arrival above a side thread of Infra's chat.
        let parent = infra.messages[1]
        let thread = ChatThread(parentMessageID: parent.id, parentSessionID: nil, hermesSessionID: nil,
                                messages: [ChatMessage(role: .user, content: "and box 3?", createdAt: now.addingTimeInterval(-3_500)),
                                           ChatMessage(role: .assistant, content: "Box 3 is up 12 days; load 1.1.", createdAt: now.addingTimeInterval(-3_490), turnState: .finished)])
        infra.threads = [thread]; store.openThreadID = thread.id
        write(names[3], await png(AnyView(ChatView(bot: infra)), store, NSSize(width: 820, height: 560)))
        store.stop()
    }
}

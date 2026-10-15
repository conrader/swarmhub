import AppKit
import SwiftUI

/// P42 shots of `--render-setup --only p42`: Infra's chat with the live card while it works for Jarvis, the sidebar with
/// Infra working for Jarvis (avatar on its working frame), the conversation sheet with Infra's steps and reply, and the
/// manager's "Install SwarmHub skills on all bots" banner. Throwaway in-memory store with a mock backend; no network,
/// no Keychain, no pollers.
@MainActor enum HeadlessP42Shots {
    static let names = ["p42-infra-live-card", "p42-sidebar-infra-working-for-jarvis", "p42-conversation-sheet", "p42-install-skills-all-bots"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.botWork.autoStart = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .hermes, hermesProfile: "grok-infra")
        let reactor = Bot(name: "Reactor", title: "Builds the app", backend: .hermes, hermesProfile: "grok-reactor")
        jarvis.avatarName = .allCases[0]; infra.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]; reactor.avatarName = .allCases[min(6, BotAvatarName.allCases.count - 1)]
        jarvis.canManageBots = true
        let now = Date.now, start = now.addingTimeInterval(-75)
        let request = "Is the backup disk on box 2 healthy, and did last night's run finish? Reply with the numbers."
        let user = BackendMessage(id: 10, role: "user", content: "[Message from grok-jarvis via SwarmHub]\n\(request)", createdAt: start)
        func tool(_ id: Int, _ name: String, _ preview: String, _ at: TimeInterval, text: String = "") -> BackendMessage {
            var row = BackendMessage(id: id, role: "assistant", content: text, createdAt: start.addingTimeInterval(at), tools: [name]); row.toolPreviews = [preview]; return row
        }
        let rows = [user, tool(11, "skill_view", "server-checks", 4), tool(12, "terminal", "smartctl -H /dev/sdb", 11),
                    tool(13, "terminal", "df -h /backup", 26, text: "SMART is fine; checking space and last night's log."), tool(14, "read_file", "/var/log/backup/nightly.log", 52)]
        let answer = "Backup disk on box 2 is healthy (SMART passed, 41 % used). Last night's run finished at 03:12: 41 GB in 38 min, no errors."
        let reply = BackendMessage(id: 15, role: "assistant", content: answer, createdAt: start.addingTimeInterval(80), finishReason: "stop")
        infra.messages = [ChatMessage(role: .user, content: "what's the uptime on box 2?", createdAt: now.addingTimeInterval(-3_600)),
                          ChatMessage(role: .assistant, content: "Box 2 has been up 41 days; load is 0.4.", createdAt: now.addingTimeInterval(-3_590), turnState: .finished)]
        jarvis.messages = [ChatMessage(role: .user, content: "ask infra whether the backup on box 2 is fine", createdAt: start.addingTimeInterval(-5))]
        reactor.messages = [ChatMessage(role: .assistant, content: "The release build is green.", createdAt: now.addingTimeInterval(-7_200), turnState: .finished)]
        // Jarvis has every SwarmHub skill (so its own banner stays away); Infra and Reactor lack the messaging ones.
        for skill in store.skillLibrary {
            jarvis.installedSkills[skill.name] = skill.version.description
            jarvis.installedSkillVariants[skill.name] = SkillLibrary.variant(of: skill, codingOrder: store.codingOrder(for: jarvis))
        }
        store.bots = [jarvis, infra, reactor]; store.selectedBot = infra

        // 1: Infra's chat, the card mid-run (four steps so far, reading the log).
        let session = BotThreadKey.sessionID(from: "grok-jarvis"), key = BotWorkCenter.Key(bot: infra.id, target: session)
        if let turn = BotWorkReader.lastTurn(rows) {
            store.applyBotWork(turn, bot: infra, session: session, origin: .bot("grok-jarvis"), key: key, start: start)
        }
        store.open(infra, remember: false)
        write(names[0], await png(AnyView(ChatView(bot: infra).environment(\.activityNow, now)), store, NSSize(width: 820, height: 640)))

        // 2: the sidebar while Infra works for Jarvis.
        let sidebar = VStack(spacing: 0) {
            ForEach([jarvis, infra, reactor]) { bot in BotRow(bot: bot, drafts: store.drafts, selected: bot.id == jarvis.id, botToDelete: .constant(nil)) }
            Spacer()
        }.padding(SidebarMetrics.listInset).frame(width: 300, height: 260).background(AppColor.sidebar).environment(\.activityNow, now)
        write(names[1], await png(AnyView(sidebar), store, NSSize(width: 300, height: 260)))

        // 3: Open conversation: Jarvis's request, Infra's steps and reply, and a later question still running.
        let later = [BackendMessage(id: 20, role: "user", content: "[Message from grok-jarvis via SwarmHub]\nAnd box 3?", createdAt: now.addingTimeInterval(-20)),
                     tool(21, "terminal", "ssh box3 df -h /backup", 70)]
        let thread = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
        store.botMessages.loaded[thread] = AppStore.threadLines(rows + [reply] + later, key: thread)
        write(names[2], await png(AnyView(BotThreadSheet(center: store.botMessages, key: thread, refresh: .seconds(3_600))), store, NSSize(width: 520, height: 560)))

        // 4: the manager's banner: Infra and Reactor lack the messaging skills.
        store.stopBotWork(); store.open(jarvis, remember: false)
        write(names[3], await png(AnyView(ChatView(bot: jarvis)), store, NSSize(width: 820, height: 420)))
    }
}

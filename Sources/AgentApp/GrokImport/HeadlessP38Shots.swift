import AppKit
import SwiftUI

/// P38a shots of `--render-setup` (`--only p38` renders just these): the Activity tab's token usage for an agent on a
/// shared profile, the Media tab's saved documents with their access, and a group's choices card answering its author.
/// Throwaway in-memory store; no network (the usage reading is set, not read).
@MainActor enum HeadlessP38Shots {
    static let names = ["p38-activity-token-usage", "p38-media-saved-documents", "p38-group-choices-card"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.botInfo.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "shared")
        let coder = Bot(name: "Coder", title: "Writes and fixes code", backend: .hermes, hermesProfile: "shared")
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .hermes, hermesProfile: "grok-infra")
        jarvis.avatarName = .allCases[0]; coder.avatarName = .allCases[min(6, BotAvatarName.allCases.count - 1)]; infra.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]
        store.bots = [jarvis, coder, infra]; store.selectedBot = jarvis
        let now = Date.now
        let sessions = [SessionUsage(id: "agentapp_jarvis", startedAt: now.addingTimeInterval(-3_600), messages: 24, inputTokens: 182_400, outputTokens: 21_350, cacheReadTokens: 96_000),
                        SessionUsage(id: "thread", startedAt: now.addingTimeInterval(-86_400 * 2), messages: 6, inputTokens: 40_210, outputTokens: 5_120, cacheReadTokens: 12_800, parentSessionID: "agentapp_jarvis"),
                        SessionUsage(id: "group", startedAt: now.addingTimeInterval(-86_400 * 3), messages: 9, inputTokens: 18_900, outputTokens: 2_640)]
        store.botUsageCache[jarvis.id] = (BotUsage(scope: .conversations, sessions: sessions), now.addingTimeInterval(-120))
        store.infoTab = .activity
        write(names[0], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 760)))

        if let artifacts = try? store.artifacts() {
            _ = try? artifacts.save(Data("Q3 board pack: revenue, churn and the hiring plan.".utf8), name: "Board pack Q3.pdf", mimeType: "application/pdf", owners: [jarvis.id, coder.id])
            _ = try? artifacts.save(Data(String(repeating: "Runbook line\n", count: 300).utf8), name: "Backup runbook.md", mimeType: "text/markdown", owners: [jarvis.id])
        }
        jarvis.messages = [ChatMessage(role: .user, content: "Here is the board pack", createdAt: now.addingTimeInterval(-600),
                                       attachments: [ChatAttachment(id: UUID(), kind: .text, name: "Board pack Q3.pdf", mimeType: "application/pdf", byteCount: 51, text: "Q3", pageCount: 12, summary: "12 pages")])]
        store.infoTab = .media
        write(names[1], await png(AnyView(InfoPanel(bot: jarvis)), store, NSSize(width: 360, height: 760)))

        let card = ChatMessage(role: .assistant, content: "Two ways to ship the backup fix:\n\n```choices\nWhich one?\n- Patch tonight\n- Wait for the weekend window\n```",
                               createdAt: now.addingTimeInterval(-60), authorID: infra.id, turnState: .finished)
        let group = GroupChat(name: "Ops", memberIDs: [jarvis.id, infra.id], messages: [
            ChatMessage(role: .user, content: "@Infra what do you suggest for the backup fix?", createdAt: now.addingTimeInterval(-120)), card])
        store.groups = [group]; store.selectedBot = nil; store.selectedGroup = group
        write(names[2], await png(AnyView(GroupChatView(group: group).frame(width: 820, height: 560).background(AppColor.chat)), store, NSSize(width: 820, height: 560)))
    }
}

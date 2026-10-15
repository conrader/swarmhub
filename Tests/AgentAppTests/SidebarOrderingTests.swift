import Foundation
import Testing
@testable import AgentApp

@Suite @MainActor struct SidebarOrderingTests {
    private func store() -> AppStore {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []; store.groups = []; store.selectedBot = nil
        return store
    }

    private func message(_ time: TimeInterval, role: MessageRole = .user, text: String = "Hello") -> ChatMessage {
        ChatMessage(role: role, content: text, createdAt: Date(timeIntervalSince1970: time))
    }

    @Test func botsAndGroupsShareNewestMessageOrderAndUpdateAfterSending() {
        let store = store()
        let old = Bot(name: "Old", messages: [message(100)]), recent = Bot(name: "Recent", messages: [message(300, role: .assistant)])
        let empty = Bot(name: "New, no messages"), group = GroupChat(name: "Crew", memberIDs: [], messages: [message(200)])
        store.bots = [old, empty, recent]; store.groups = [group]
        #expect(store.sidebarChats.map(\.id) == [recent.id, group.id, old.id, empty.id])
        old.messages.append(message(400))
        #expect(store.sidebarChats.map(\.id) == [old.id, recent.id, group.id, empty.id])
        store.open(old); store.moveChatSelection(by: 1)
        #expect(store.selectedBot === recent)
        store.moveChatSelection(by: 1)
        #expect(store.selectedGroup === group)
    }

    @Test func timestampsWinOverArrayOrderAndDraftsNoticesAndEmptyRepliesDoNotMoveChats() {
        let store = store()
        let a = Bot(name: "A", messages: [message(300), message(100)])
        let b = Bot(name: "B", messages: [message(200), message(500, role: .system), message(600, role: .assistant, text: " ")])
        let hidden = Bot(name: "Hidden", isHidden: true, messages: [message(1000)])
        store.bots = [b, hidden, a]; store.drafts.set("Unsent", for: b.id)
        #expect(store.sidebarChats.map(\.id) == [a.id, b.id])
        b.messages.append(message(700, role: .assistant, text: "```swarmhub\n{\"op\":\"bots\",\"list\":[]}\n```"))
        #expect(store.sidebarChats.map(\.id) == [a.id, b.id])
        b.messages.append(ChatMessage(role: .user, content: "", createdAt: Date(timeIntervalSince1970: 800),
                                      attachments: [.init(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 5)]))
        #expect(store.sidebarChats.first?.id == b.id)
    }

    @Test func threadAndArchivedMessagesCountAndEqualDatesStayStable() throws {
        let store = store()
        let a = Bot(name: "A", messages: [message(200)]), b = Bot(name: "B", messages: [message(200)]), c = Bot(name: "Archive")
        store.bots = [a, b, c]
        #expect(store.sidebarChats.map(\.id) == [a.id, b.id, c.id])
        b.threads = [ChatThread(parentMessageID: UUID(), parentSessionID: nil, hermesSessionID: nil, messages: [message(300)])]
        #expect(store.sidebarChats.map(\.id) == [b.id, a.id, c.id])
        try store.grokHistory.merge([ArchivedMessage(id: "new", seq: 1, role: "assistant", text: "Imported reply",
                                                     timestamp: Date(timeIntervalSince1970: 400), hidden: false, channel: "main")], sourceID: "fixture", for: c.id)
        #expect(store.sidebarChats.map(\.id) == [c.id, b.id, a.id])
    }
}

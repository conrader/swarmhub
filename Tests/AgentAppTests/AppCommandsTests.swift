import SwiftUI
import Testing
@testable import AgentApp

@Suite @MainActor struct AppCommandsTests {
    private func store() -> AppStore {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false,
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []; store.groups = []; store.selectedBot = nil; store.selectedGroup = nil
        return store
    }

    @Test func navigationRecoversFromAMissingSelectionAndHandlesEmptyLists() {
        let store = store()
        store.moveChatSelection(by: 1)
        #expect(store.selectedBot == nil && store.selectedGroup == nil)
        let a = Bot(name: "A"), group = GroupChat(name: "Crew", memberIDs: [a.id])
        store.bots = [a]; store.groups = [group]
        store.moveChatSelection(by: -1)
        #expect(store.selectedGroup === group)
        store.selectedGroup = nil; store.selectedBot = Bot(name: "Removed")
        store.moveChatSelection(by: 1)
        #expect(store.selectedBot === a)
    }

    @Test func commandsDoNotOpenAnotherSheetOrNavigateBehindADialog() {
        let store = store(), bot = Bot(name: "A")
        store.bots = [bot]; store.open(bot)
        AppCommand.newAgent.performWorkspaceAction(in: store)
        #expect(store.showingNewBot)
        #expect(!AppCommand.newGroup.isEnabled(in: store))
        #expect(!AppCommand.agentSettings.isEnabled(in: store))
        AppCommand.newGroup.performWorkspaceAction(in: store)
        #expect(!store.showingNewGroup)
        #expect(AppCommand.settings.isEnabled(in: store))
        store.showingNewBot = false
        AppCommand.agentSettings.performWorkspaceAction(in: store)
        #expect(store.editingBot === bot)
        #expect(!AppCommand.quickSwitcher.isEnabled(in: store))
    }

    @Test func appShortcutsDoNotCollide() {
        let bindings = AppCommand.allCases.map { "\($0.modifiers.rawValue):\($0.key.character)" }
        #expect(Set(bindings).count == bindings.count)
    }
}

@Suite @MainActor struct WorkspaceActivityTests {
    @Test func activityLinksWorkToItsOwnChat() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false,
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let coder = Bot(name: "Coder", backend: .mock), reader = Bot(name: "Reader", backend: .mock)
        let hidden = Bot(name: "Hidden", backend: .mock)
        let group = GroupChat(name: "Release", memberIDs: [coder.id])
        store.bots = [coder, reader, hidden]
        store.groups = [group]
        store.open(reader)
        let turn = store.beginTurn(in: group, bot: coder, assistant: nil)
        let queued = ChatMessage(role: .user, content: "Compile")
        store.turns.nextMessages = [QueuedNextMessage(conversation: reader, bubble: queued)]
        hidden.isHidden = true
        hidden.manualUnread = true
        reader.unreadCount = 1

        func item(_ id: UUID) -> WorkspaceActivityItem? { store.workspaceActivity().first { $0.id == id } }
        #expect(item(group.id)?.section == .working)
        #expect(item(reader.id)?.section == .queued)
        #expect(item(coder.id) == nil && item(hidden.id) == nil)
        store.herdrPromptBook.turnWaits[group.id] = (coder.id, "Codex")
        store.herdrPrompts[group.id] = HerdrPrompt(program: "Codex", since: .now)
        #expect(item(group.id)?.section == .attention)
        #expect(item(group.id)?.detail.contains(coder.name) == true)
        store.herdrPrompts[group.id] = nil
        store.herdrPromptBook.turnWaits[group.id] = nil
        store.endTurn(turn.token)
        store.turns.nextMessages = []
        #expect(item(reader.id)?.section == .unread)
        #expect(item(group.id) == nil)
        let reply = ChatMessage(role: .assistant, content: "Interrupted")
        reply.turnState = .incomplete
        group.messages = [reply]
        #expect(item(group.id)?.section == .attention)
        reply.checkingSavedReply = true
        #expect(item(group.id)?.section == .working)
        reply.checkingSavedReply = false
        reply.turnState = .finished
        store.open(try #require(item(reader.id)).chat)
        #expect(store.workspaceActivity().isEmpty)
    }
}

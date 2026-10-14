import SwiftUI
import Testing
@testable import AgentApp

@Suite @MainActor struct AppCommandsTests {
    private func store() -> AppStore {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                             keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []; store.groups = []; store.selectedBot = nil; store.selectedGroup = nil
        return store
    }

    @Test func navigationFollowsSidebarOrderSkipsHiddenChatsAndWraps() {
        let store = store()
        let a = Bot(name: "A"), hidden = Bot(name: "Hidden", isHidden: true), b = Bot(name: "B")
        let group = GroupChat(name: "Crew", memberIDs: [a.id, b.id])
        let hiddenGroup = GroupChat(name: "Hidden group", memberIDs: []); hiddenGroup.isHidden = true
        store.bots = [a, hidden, b]; store.groups = [hiddenGroup, group]
        store.open(a)
        store.openThreadID = UUID()
        b.manualUnread = true
        AppCommand.nextChat.performWorkspaceAction(in: store)
        #expect(store.selectedBot === b)
        #expect(store.openThreadID == nil && !b.isUnread)
        AppCommand.nextChat.performWorkspaceAction(in: store)
        #expect(store.selectedGroup === group)
        AppCommand.nextChat.performWorkspaceAction(in: store)
        #expect(store.selectedBot === a && store.selectedGroup == nil)
        AppCommand.previousChat.performWorkspaceAction(in: store)
        #expect(store.selectedGroup === group)
        #expect(store.defaults.string(forKey: AppStore.lastChatKey) == AppStore.chatKey(group: group.id))
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

    @Test func contextualCommandsFollowTheActiveConversationAndComputerConfiguration() {
        let store = store()
        #expect(!AppCommand.agentSettings.isEnabled(in: store))
        #expect(!AppCommand.toggleInfo.isEnabled(in: store))
        #expect(!AppCommand.stopResponse.isEnabled(in: store))
        let bot = Bot(name: "A")
        store.bots = [bot]; store.open(bot)
        #expect(AppCommand.agentSettings.isEnabled(in: store))
        #expect(!AppCommand.openComputer.isEnabled(in: store))
        bot.computerURL = "https://desktop.example.test"
        #expect(AppCommand.openComputer.isEnabled(in: store))
        store.openThreadID = UUID()
        #expect(AppCommand.backToChat.isEnabled(in: store))
        let group = GroupChat(name: "Crew", memberIDs: [bot.id])
        store.groups = [group]; store.open(group)
        // Opening a group can leave selectedBot populated; group selection must win.
        #expect(!AppCommand.agentSettings.isEnabled(in: store))
        #expect(!AppCommand.openComputer.isEnabled(in: store))
        #expect(!AppCommand.routines.isEnabled(in: store))
        #expect(AppCommand.members.isEnabled(in: store))
        store.showInfo = false
        AppCommand.members.performWorkspaceAction(in: store)
        #expect(store.showInfo)
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

    @Test func detailShortcutsOpenThePanelAndSelectItsContent() {
        let store = store(), bot = Bot(name: "A")
        store.bots = [bot]; store.open(bot); store.showInfo = false
        AppCommand.media.performWorkspaceAction(in: store)
        #expect(store.showInfo && store.infoTab == .media)
        AppCommand.routines.performWorkspaceAction(in: store)
        #expect(store.infoTab == .routines)
        store.sidebarHidden = true
        AppCommand.hiddenChats.performWorkspaceAction(in: store)
        #expect(!store.sidebarHidden && store.showingHiddenBots)
    }

    @Test func appShortcutsDoNotCollide() {
        let bindings = AppCommand.allCases.map { "\($0.modifiers.rawValue):\($0.key.character)" }
        #expect(Set(bindings).count == bindings.count)
    }
}

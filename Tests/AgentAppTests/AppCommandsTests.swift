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

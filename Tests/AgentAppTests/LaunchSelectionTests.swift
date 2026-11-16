import Foundation
import Testing
@testable import AgentApp

// P18 item 9: launch, delete and hide never leave a hidden bot or group selected.

@MainActor private func serverDefaults() -> UserDefaults {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey); return defaults
}

/// Saves `bots` and `groups` to a fresh store file, then launches a second store from it with the same defaults.
@MainActor private func relaunch(bots: [Bot], groups: [GroupChat] = [], defaults: UserDefaults, url: URL = temporaryStore()) -> AppStore {
    let first = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    first.bots = bots; first.groups = groups; first.save()
    return AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
}

@Test @MainActor func launchNeverSelectsTheHiddenDemoBotStoredFirst() {
    let atlas = Bot(name: "Atlas", isDemo: true), jarvis = Bot(name: "Jarvis", backend: .herdr)
    let store = relaunch(bots: [atlas, jarvis], defaults: serverDefaults())
    #expect(store.bots.first?.name == "Atlas" && store.bots.first?.isHidden == true)
    #expect(store.selectedBot?.name == "Jarvis"); #expect(store.selectedGroup == nil)
    var errors: [String] = []
    #expect(UISmoke.launchSelection(store, errors: &errors)["name"] as? String == "Jarvis"); #expect(errors.isEmpty)
}

@Test @MainActor func launchRestoresTheLastOpenedBotOrGroup() {
    let defaults = serverDefaults(), url = temporaryStore()
    let a = Bot(name: "A", backend: .herdr), b = Bot(name: "B", backend: .herdr), group = GroupChat(name: "Crew", memberIDs: [a.id, b.id])
    let first = relaunch(bots: [a, b], groups: [group], defaults: defaults, url: url)
    first.open(first.bots[1])
    let second = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(second.selectedBot?.id == b.id)
    second.open(second.groups[0])
    let third = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(third.selectedGroup?.id == group.id); #expect(third.selectedBot == nil)
}

@Test @MainActor func aRememberedChatThatIsNowHiddenIsNotRestored() {
    let defaults = serverDefaults(), a = Bot(name: "A", backend: .herdr), b = Bot(name: "B", backend: .herdr, isHidden: true)
    defaults.set(AppStore.chatKey(bot: b.id), forKey: AppStore.lastChatKey)
    #expect(relaunch(bots: [a, b], defaults: defaults).selectedBot?.id == a.id)
}

@Test @MainActor func smokeOpeningABotDoesNotChangeTheRememberedChat() {
    let defaults = serverDefaults(), a = Bot(name: "A", backend: .herdr), b = Bot(name: "B", backend: .herdr)
    let store = relaunch(bots: [a, b], defaults: defaults)
    store.open(store.bots[0]); store.open(store.bots[1], remember: false)
    #expect(defaults.string(forKey: AppStore.lastChatKey) == AppStore.chatKey(bot: a.id))
}

@Test @MainActor func deletingOrHidingTheSelectedChatMovesToAVisibleOne() {
    let hiddenFirst = Bot(name: "Hidden", backend: .herdr, isHidden: true)
    let a = Bot(name: "A", backend: .herdr), b = Bot(name: "B", backend: .herdr), group = GroupChat(name: "Crew", memberIDs: [a.id])
    let store = relaunch(bots: [hiddenFirst, a, b], groups: [group], defaults: serverDefaults())
    #expect(store.selectedBot?.name == "A")
    store.delete(store.selectedBot!)
    #expect(store.selectedBot?.name == "B")
    store.setHidden(store.selectedBot!, true)
    #expect(store.selectedBot == nil); #expect(store.selectedGroup?.name == "Crew")
    store.setHidden(store.groups[0], true)
    #expect(store.selectedBot == nil); #expect(store.selectedGroup == nil)
    // Hiding a chat that is not open leaves the selection alone.
    store.setHidden(store.bots[1], false); store.open(store.bots[1]); store.setHidden(store.bots[0], true)
    #expect(store.selectedBot?.name == "B")
}

@Test @MainActor func deletingTheSelectedGroupMovesToAVisibleChat() {
    let hiddenFirst = Bot(name: "Hidden", backend: .herdr, isHidden: true), a = Bot(name: "A", backend: .herdr)
    let store = relaunch(bots: [hiddenFirst, a], groups: [GroupChat(name: "Crew", memberIDs: [a.id])], defaults: serverDefaults())
    store.open(store.groups[0]); store.deleteGroup(store.groups[0])
    #expect(store.selectedGroup == nil); #expect(store.selectedBot?.name == "A")
}

@Test @MainActor func everythingHiddenGivesTheWelcomeState() {
    let group = GroupChat(name: "Crew", memberIDs: []); group.isHidden = true
    let store = relaunch(bots: [Bot(name: "Atlas", isDemo: true), Bot(name: "Quiet", backend: .herdr, isHidden: true)], groups: [group], defaults: serverDefaults())
    #expect(store.selectedBot == nil); #expect(store.selectedGroup == nil)
    var errors: [String] = []
    #expect(UISmoke.launchSelection(store, errors: &errors)["kind"] as? String == "none"); #expect(errors.isEmpty)
}


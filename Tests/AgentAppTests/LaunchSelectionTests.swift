import Foundation
import Testing
@testable import AgentApp

// P18 item 9: launch, delete and hide never leave a hidden bot or group selected.

@MainActor private func hermesDefaults() -> UserDefaults {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8642/v1", forKey: "hermesBaseURL"); return defaults
}

/// Saves `bots` and `groups` to a fresh store file, then launches a second store from it with the same defaults.
@MainActor private func relaunch(bots: [Bot], groups: [GroupChat] = [], defaults: UserDefaults, url: URL = temporaryStore()) -> AppStore {
    let first = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    first.bots = bots; first.groups = groups; first.save()
    return AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
}

@Test @MainActor func launchNeverSelectsTheHiddenDemoBotStoredFirst() {
    let atlas = Bot(name: "Atlas", isDemo: true), jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    let store = relaunch(bots: [atlas, jarvis], defaults: hermesDefaults())
    #expect(store.bots.first?.name == "Atlas" && store.bots.first?.isHidden == true)
    #expect(store.selectedBot?.name == "Jarvis"); #expect(store.selectedGroup == nil)
    var errors: [String] = []
    #expect(UISmoke.launchSelection(store, errors: &errors)["name"] as? String == "Jarvis"); #expect(errors.isEmpty)
}

@Test @MainActor func launchRestoresTheLastOpenedBotOrGroup() {
    let defaults = hermesDefaults(), url = temporaryStore()
    let a = Bot(name: "A", backend: .hermes), b = Bot(name: "B", backend: .hermes), group = GroupChat(name: "Crew", memberIDs: [a.id, b.id])
    let first = relaunch(bots: [a, b], groups: [group], defaults: defaults, url: url)
    first.open(first.bots[1])
    let second = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(second.selectedBot?.id == b.id)
    second.open(second.groups[0])
    let third = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(third.selectedGroup?.id == group.id); #expect(third.selectedBot == nil)
}

@Test @MainActor func aRememberedChatThatIsNowHiddenIsNotRestored() {
    let defaults = hermesDefaults(), a = Bot(name: "A", backend: .hermes), b = Bot(name: "B", backend: .hermes, isHidden: true)
    defaults.set(AppStore.chatKey(bot: b.id), forKey: AppStore.lastChatKey)
    #expect(relaunch(bots: [a, b], defaults: defaults).selectedBot?.id == a.id)
}

@Test @MainActor func smokeOpeningABotDoesNotChangeTheRememberedChat() {
    let defaults = hermesDefaults(), a = Bot(name: "A", backend: .hermes), b = Bot(name: "B", backend: .hermes)
    let store = relaunch(bots: [a, b], defaults: defaults)
    store.open(store.bots[0]); store.open(store.bots[1], remember: false)
    #expect(defaults.string(forKey: AppStore.lastChatKey) == AppStore.chatKey(bot: a.id))
}

@Test @MainActor func deletingOrHidingTheSelectedChatMovesToAVisibleOne() {
    let hiddenFirst = Bot(name: "Hidden", backend: .hermes, isHidden: true)
    let a = Bot(name: "A", backend: .hermes), b = Bot(name: "B", backend: .hermes), group = GroupChat(name: "Crew", memberIDs: [a.id])
    let store = relaunch(bots: [hiddenFirst, a, b], groups: [group], defaults: hermesDefaults())
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
    let hiddenFirst = Bot(name: "Hidden", backend: .hermes, isHidden: true), a = Bot(name: "A", backend: .hermes)
    let store = relaunch(bots: [hiddenFirst, a], groups: [GroupChat(name: "Crew", memberIDs: [a.id])], defaults: hermesDefaults())
    store.open(store.groups[0]); store.deleteGroup(store.groups[0])
    #expect(store.selectedGroup == nil); #expect(store.selectedBot?.name == "A")
}

@Test @MainActor func everythingHiddenGivesTheWelcomeState() {
    let group = GroupChat(name: "Crew", memberIDs: []); group.isHidden = true
    let store = relaunch(bots: [Bot(name: "Atlas", isDemo: true), Bot(name: "Quiet", backend: .hermes, isHidden: true)], groups: [group], defaults: hermesDefaults())
    #expect(store.selectedBot == nil); #expect(store.selectedGroup == nil)
    var errors: [String] = []
    #expect(UISmoke.launchSelection(store, errors: &errors)["kind"] as? String == "none"); #expect(errors.isEmpty)
}

@Test @MainActor func profileSetupSelectsOnlyAVisibleBot() async throws {
    let defaults = hermesDefaults(), url = temporaryStore()
    let store = relaunch(bots: [Bot(name: "Atlas", isDemo: true)], defaults: defaults, url: url)
    #expect(store.selectedBot == nil)
    let (host, session) = MockHermesProtocol.serve(hermesModelsHandler(multiplex: true, served: []))
    defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    let probing = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults, hermesSession: session)
    #expect(probing.selectedBot == nil)
    await probing.refreshHermesAgents()
    let added = try #require(probing.bots.first { $0.backend == .hermes })
    #expect(probing.selectedBot?.id == added.id)
}

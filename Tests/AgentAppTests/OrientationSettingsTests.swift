import Foundation
import Testing
@testable import AgentApp

// P49: Settings → Advanced → Orientation: the on/off switch, the coordinator picker and the quiet hours, as the
// orientation turn uses them. Isolated settings; no network, Keychain, browser or microphone.

@MainActor private func settingsStore() -> (AppStore, Bot, Bot, Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), infra = Bot(name: "Infra", backend: .hermes, hermesProfile: "infra")
    let scout = Bot(name: "Scout", backend: .hermes, hermesProfile: "scout")
    store.bots = [jarvis, infra, scout]
    return (store, jarvis, infra, scout)
}

@MainActor @Test func theCoordinatorPickerOverridesTheDefaultButNeverMakesABotItsOwn() {
    let (store, jarvis, infra, scout) = settingsStore()
    #expect(store.orientationCoordinatorChoice == .automatic && store.orientationCoordinator(for: scout) === jarvis)
    store.orientationCoordinatorChoice = .bot(infra.id)
    #expect(store.defaults.string(forKey: OrientationCoordinatorChoice.key) == infra.id.uuidString)
    #expect(store.orientationCoordinator(for: scout) === infra && store.orientationPrompt(for: scout).contains("Coordinator: Infra (profile infra)"))
    #expect(store.orientationCoordinator(for: infra) === jarvis, "the chosen bot itself falls back to the default")
    store.orientationCoordinatorChoice = .none
    #expect(store.orientationCoordinator(for: scout) == nil && store.orientationPrompt(for: scout).contains("Coordinator: none (report to Konrad only)"))
    store.defaults.set(UUID().uuidString, forKey: OrientationCoordinatorChoice.key)
    #expect(store.orientationCoordinator(for: scout) === jarvis, "a deleted bot falls back to the default")
    #expect(OrientationCoordinatorChoice(stored: "junk") == .automatic && OrientationCoordinatorChoice.automatic.stored == nil)
}

@MainActor @Test func quietHoursDefaultTo22To08AndTheChoiceReachesThePrompt() throws {
    let (store, _, _, scout) = settingsStore()
    store.heartbeatTimeZone = try #require(TimeZone(identifier: "Europe/Warsaw"))
    #expect(store.quietHours == QuietHours(start: 22 * 60, end: 8 * 60) && store.quietHours.label == "22:00–08:00")
    store.quietHours = QuietHours(start: 23 * 60, end: 7 * 60)
    #expect(store.defaults.integer(forKey: QuietHours.startKey) == 1_380 && store.defaults.integer(forKey: QuietHours.endKey) == 420)
    let text = store.orientationPrompt(for: scout)
    #expect(text.contains("Quiet hours: 23:00–07:00 Warsaw time") && text.contains("\"after 07:00 Warsaw\""))
    store.defaults.set(9_999, forKey: QuietHours.startKey)
    #expect(store.quietHours.start == QuietHours.defaultStart, "a broken value reads as the default")
}

@MainActor @Test func theSwitchInSettingsTurnsOrientationOffAndOnAgain() {
    let (store, _, _, scout) = settingsStore()
    #expect(store.orientationEnabledSetting, "on by default")
    store.orientationEnabledSetting = false
    store.queueOrientation(scout)
    #expect(!store.orientationPending(scout) && store.defaults.object(forKey: OrientationCopy.enabledKey) as? Bool == false)
    store.orientationEnabledSetting = true; store.queueOrientation(scout)
    #expect(store.orientationPending(scout))
    #expect(SettingsLayout.ids(in: .orientation) == ["orientation.newBots", "orientation.quietHours"])
    #expect(SettingsLayout.path(.orientation) == "Settings → Advanced → Orientation")
}

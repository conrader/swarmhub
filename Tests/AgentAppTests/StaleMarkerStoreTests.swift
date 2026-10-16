import Foundation
import Testing
@testable import AgentApp

/// P54 items 4–5 through the store: the marker instructions reach every apps-enabled turn (after a restart, a `/goal`
/// continuation, a turn answering a bot message), and a turn that still ends with an app request shows it folded with a
/// "not run" line. Composio is `MockHermesProtocol`; nothing reaches the network or the Keychain.

@MainActor private func appsStore(directory: URL, keys: InMemoryKeyStore, host: String, session: URLSession) -> ConnectedAppsStore {
    ConnectedAppsStore(directory: directory, keyStore: keys, session: session, apiURL: URL(string: "https://\(host)/api/v3.1/")!)
}

@MainActor private func plainsayStore(_ backend: MarkerBot, url: URL = temporaryStore()) async -> (AppStore, Bot, ConnectedAppsStore) {
    let (apps, _, _) = composioFixture(handler: composioReadHandler); await apps.refresh()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat")
    store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    return (store, bot, apps)
}

@MainActor @Test func theMarkerInstructionsReachTheFirstTurnAfterARestart() async throws {
    let (host, session) = MockHermesProtocol.serve(composioReadHandler)
    let directory = temporaryStore().deletingLastPathComponent(), keys = InMemoryKeyStore(), url = temporaryStore()
    let apps = appsStore(directory: directory, keys: keys, host: host, session: session)
    _ = apps.saveKey(syntheticComposioKey); await apps.refresh()
    let first = MarkerBot(["OLD" + markerSearch, "Hello."])
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in first }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.connectedApps = apps
    let bot = Bot(name: "Plainsay", backend: .hermes, hermesSessionID: "existing-chat"); store.bots = [bot]; store.selectedBot = bot
    apps.setAllowed(true, account: apps.accounts[0], botID: bot.id)
    #expect(store.send(text: "Hi", bot: bot, conversation: bot, replyToID: nil))
    try await waitUntil { !store.anyTurnRunning }
    store.save()

    let later = MarkerBot([markerSearch, "Found them."])
    let restarted = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in later }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    restarted.connectedApps = appsStore(directory: directory, keys: keys, host: host, session: session)
    let again = try #require(restarted.bots.first { $0.id == bot.id })
    #expect(restarted.send(text: "List my repos", bot: again, conversation: again, replyToID: nil))
    try await waitUntil { !restarted.anyTurnRunning }
    let calls = await later.recorded()
    let before = try #require(MarkerBot.marker((await first.recorded())[0]))
    #expect(calls.count == 2 && calls.allSatisfy { MarkerBot.marker($0) != nil }, "the instructions are in every step after the restart")
    #expect(MarkerBot.marker(calls[0]) != before, "a fresh marker for the new turn")
    #expect(again.messages.last?.content == "Found them.")
}

@MainActor @Test func aGoalContinuationCarriesTheMarkerInstructions() async throws {
    let backend = MarkerBot(["Round one done.", "Round two done."])
    let (store, bot, _) = await plainsayStore(backend)
    store.defaults.set(2, forKey: GoalProtocol.roundsKey)
    #expect(store.submitComposer(text: "/goal keep the inbox tidy"))
    try await waitUntil { store.goal(in: bot)?.state == .ended }
    let calls = await backend.recorded()
    #expect(calls.count == 2)
    let continuation = try #require(calls.last)
    #expect(continuation.messages.last?.content.hasPrefix("Continue toward the goal") == true)
    #expect(calls.allSatisfy { MarkerBot.marker($0) != nil })
}

@MainActor @Test func aTurnAnsweringABotMessageCarriesTheMarkerInstructions() async throws {
    let backend = MarkerBot([markerSearch, "Two repos."])
    let (store, bot, _) = await plainsayStore(backend)
    #expect(store.send(text: "[Message from grok-jarvis via SwarmHub]\nList Konrad's GitHub repositories", bot: bot, conversation: bot, replyToID: nil))
    try await waitUntil { !store.anyTurnRunning }
    let calls = await backend.recorded()
    #expect(calls.count == 2 && calls.allSatisfy { MarkerBot.marker($0) != nil })
    #expect(bot.messages.last?.content == "Two repos.")
}

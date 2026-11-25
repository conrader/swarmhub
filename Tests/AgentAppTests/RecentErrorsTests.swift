import Foundation
import Testing
@testable import AgentApp

@MainActor @Test func dismissedErrorsKeepOnlyTheirSafeCategoryAndOriginalBot() throws {
    let defaults = isolatedDefaults()
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let bot = Bot(name: "Fixture"), other = Bot(name: "Other")
    store.bots = [bot, other]
    let privateText = "fixture-secret-command-and-address"
    for _ in 0...AppStore.recentErrorLimit {
        store.presentError(privateText, reason: .send, bot: bot)
        store.selectedBot = other
        store.dismissError()
        store.dismissError()
    }
    #expect(store.recentErrors.count == AppStore.recentErrorLimit)
    #expect(store.recentErrors.allSatisfy { $0.botID == bot.id && $0.reason == .send })
    store.errorMessage = privateText
    store.dismissError()
    #expect(store.recentErrors.first?.botID == nil && store.recentErrors.first?.reason == .operation)
    let raw = try #require(defaults.data(forKey: AppStore.recentErrorsKey))
    #expect(!String(decoding: raw, as: UTF8.self).contains(privateText))
}

import Foundation
import Testing
import SwarmHubCore
@testable import AgentApp

private struct ReceivedPromptTransport: BotPromptSyncTransport {
    let remote: BotPromptDocument
    func exchange(_ document: BotPromptDocument) async throws -> BotPromptDocument { remote }
}

@MainActor @Test func macPromptSyncSurvivesRelaunchWithoutWritingBackSettingsOrPersona() async throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let defaults = isolatedDefaults()
    defaults.set("https://Box.Example/v1/", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let bot = Bot(name: "Scout", persona: "Keep this persona exact.", backend: .hermes, hermesProfile: "scout")
    store.bots = [bot]
    let originalOwner = store.userName
    _ = try store.defaultBotInstructions(for: bot)
    let key = BotPromptDocument.botKey(try ConnectionAddress("https://box.example", profile: "scout"))
    var phone = BotPromptSyncState()
    phone.edit(key: key, origin: "phone", now: 100, fallback: BotPromptContext(name: "Scout")) {
        $0.owner = "Owner set on phone"
    }
    #expect(try await store.syncBotPrompts(using: ReceivedPromptTransport(remote: phone.document)))
    #expect(try store.defaultBotInstructions(for: bot).contains("Owner set on phone"))
    #expect(store.userName == originalOwner)
    #expect(bot.persona == "Keep this persona exact.")

    let restarted = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    restarted.bots = [bot]
    #expect(try restarted.defaultBotInstructions(for: bot).contains("Owner set on phone"))
    #expect(restarted.userName == originalOwner)
    #expect(restarted.botPromptSync?.state.observed[key]?.owner == originalOwner)
}

@MainActor @Test func macPromptSyncDemoNeverWritesAStateFile() throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AppStore(demoMode: true, storeURL: url, autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Scout", backend: .hermes, hermesProfile: "scout")
    _ = try store.defaultBotInstructions(for: bot)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json").path))
}

@MainActor @Test func macPromptSyncCorruptFileIsSurfacedAndNeverOverwritten() throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let syncURL = url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json")
    let bytes = Data("invalid state".utf8)
    try bytes.write(to: syncURL)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    #expect(store.botPromptSync == nil)
    #expect(store.errorMessage?.contains("sync file was kept unchanged") == true)
    let bot = Bot(name: "Scout", backend: .hermes)
    #expect(throws: CoreError.storage) { _ = try store.defaultBotInstructions(for: bot) }
    #expect(try Data(contentsOf: syncURL) == bytes)
}

@MainActor @Test func macOnlyHTTPConnectionsKeepTheirExistingLocalPromptBehavior() throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Scout", backend: .hermes)
    bot.hermesBaseURL = "http://desktop-only.example"
    #expect(try store.defaultBotInstructions(for: bot).contains("Scout"))
    #expect(store.botPromptSync?.state.document.bots.isEmpty == true)
}

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
    let defaults = isolatedDefaults()
    defaults.set("https://box.example", forKey: "hermesBaseURL")
    let store = AppStore(demoMode: true, storeURL: url, autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(), defaults: defaults)
    let bot = Bot(name: "Scout", backend: .hermes, hermesProfile: "scout")
    _ = try store.defaultBotInstructions(for: bot)
    #expect(store.botPromptSync?.state.document.bots.isEmpty == false)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json").path))
}

@MainActor @Test(arguments: ["invalid state", "{\"origin\":\"device\",\"state\":{\"document\":{\"schema\":99,\"bots\":{}},\"observed\":{}}}"])
func macPromptSyncCorruptFileWarnsButKeepsChatWorkingWithoutOverwriting(saved: String) throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let syncURL = url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json")
    let bytes = Data(saved.utf8)
    try bytes.write(to: syncURL)
    let defaults = isolatedDefaults()
    defaults.set("https://box.example", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.botPromptSync == nil)
    #expect(store.botPromptSyncWarning?.contains("sync file was kept unchanged") == true)
    #expect(store.errorMessage == nil)
    let bot = Bot(name: "Scout", backend: .hermes)
    #expect(try store.defaultBotInstructions(for: bot).contains("Scout"))
    store.userName = "Local owner after sync failure"
    let backend = try #require(try store.backend(for: bot) as? HermesBackend)
    #expect(backend.defaultInstructions?.contains(store.userName) == true)
    #expect(store.errorMessage == nil)
    #expect(store.persistenceEnabled)
    #expect(try Data(contentsOf: syncURL) == bytes)
}

@MainActor @Test func macPromptSyncFailedObservationWarnsAndUsesLocalSettingsInsteadOfSyncedValues() throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let defaults = isolatedDefaults()
    defaults.set("https://box.example", forKey: "hermesBaseURL")
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    let bot = Bot(name: "Scout", backend: .hermes)
    _ = try store.defaultBotInstructions(for: bot)
    let seed = try #require(store.botPromptSync)
    let key = BotPromptDocument.botKey(try ConnectionAddress("https://box.example"))
    try seed.edit(key: key, now: 100, fallback: BotPromptContext(name: "Scout")) { $0.owner = "Remote owner" }
    let syncURL = url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json")
    let bytes = try Data(contentsOf: syncURL)
    var writeAttempts = 0
    let sync = try BotPromptSyncStore(fileURL: syncURL, writeFile: { _, destination in
        #expect(destination == syncURL)
        writeAttempts += 1
        throw CoreError.storage
    })
    store.botPromptSync = sync
    let before = sync.state
    store.userName = "Changed local owner"
    let backend = try #require(try store.backend(for: bot) as? HermesBackend)
    #expect(backend.defaultInstructions?.contains("Changed local owner") == true)
    #expect(backend.defaultInstructions?.contains("Remote owner") == false)
    #expect(store.botPromptSyncWarning?.contains("Chat is using local settings") == true)
    #expect(store.errorMessage == nil)
    #expect(writeAttempts == 1)
    #expect(sync.state == before)
    #expect(try Data(contentsOf: syncURL) == bytes)
    #expect(store.persistenceEnabled)
}

// nil exercises the app's default URL rather than a per-bot override.
@MainActor @Test(arguments: [nil, "http://localhost:18000", "http://127.0.0.1:18000",
                            "http://[::1]:18000", "http://desktop-only.example"] as [String?])
func macOnlyHTTPConnectionsKeepTheirExistingLocalPromptBehavior(address: String?) throws {
    let url = temporaryStore()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Scout", backend: .hermes)
    bot.hermesBaseURL = address
    #expect(try store.defaultBotInstructions(for: bot).contains("Scout"))
    #expect(store.botPromptSync?.state.document.bots.isEmpty == true)
    #expect(store.botPromptSync?.state.observed.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("bot-prompt-sync.json").path))
}

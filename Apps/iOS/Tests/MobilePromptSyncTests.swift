import Foundation
import Testing
import SwarmHubCore
@testable import SwarmHub

private func mobilePromptDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor @Test(arguments: ["broken json", "{\"origin\":\"phone\",\"state\":{\"document\":{\"schema\":99,\"bots\":{}},\"observed\":{}}}"])
func mobilePromptLoadWarningSurvivesStatusNoticesAndFailedRetryUntilDismissed(saved: String) async throws {
    let directory = try mobilePromptDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("bot-prompt-sync.json")
    let bytes = Data(saved.utf8)
    try bytes.write(to: url)
    let store = MobileStore(storageDirectory: directory)
    let warning = try #require(store.botPromptSyncWarning)
    #expect(warning.contains("Chat is using local settings"))
    #expect(store.storageReady)
    #expect(store.error == nil)
    #expect(store.notice == nil)
    await store.load()
    #expect(store.booted)
    for status in ["Stop requested.", "The server accepted the approval.", "Turn completed."] {
        store.notice = status
        #expect(store.botPromptSyncWarning == warning)
        #expect(store.notice == status)
    }
    store.retryBotPromptSyncLoad()
    #expect(store.botPromptSyncWarning == warning)
    #expect(store.error == nil)
    #expect(try Data(contentsOf: url) == bytes)
    store.dismissBotPromptSyncWarning()
    store.notice = "Another status"
    #expect(store.botPromptSyncWarning == nil)
    #expect(try Data(contentsOf: url) == bytes)
}

@MainActor @Test func mobilePromptWarningClearsWhenLocalLoadingRecovers() throws {
    let directory = try mobilePromptDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("bot-prompt-sync.json")
    try Data("broken json".utf8).write(to: url)
    let store = MobileStore(storageDirectory: directory)
    #expect(store.botPromptSyncWarning != nil)
    store.notice = "Status stays independent"

    // Simulate an external repair. The app's retry must only read the repaired file.
    try FileManager.default.removeItem(at: url)
    let repaired = try BotPromptSyncStore(fileURL: url)
    let address = try ConnectionAddress("https://box.example")
    let profile = AgentProfile(name: "Scout", address: address)
    let key = BotPromptDocument.botKey(address)
    try repaired.edit(key: key, now: 100, fallback: BotPromptContext(name: "Scout")) { $0.owner = "Recovered owner" }
    let bytes = try Data(contentsOf: url)
    store.retryBotPromptSyncLoad()
    #expect(store.botPromptSyncWarning == nil)
    #expect(store.notice == "Status stays independent")
    #expect(store.error == nil)
    #expect(try Data(contentsOf: url) == bytes)

    // The recovered store remains usable and preserves the recovered fields on a later edit.
    store.profiles = [profile]
    try store.editBotPrompt(profile.id) { $0.role = "Recovered role" }
    let reopened = try BotPromptSyncStore(fileURL: url)
    let context = reopened.context(for: key, fallback: BotPromptContext(name: "Scout"))
    #expect(context.owner == "Recovered owner")
    #expect(context.role == "Recovered role")
}

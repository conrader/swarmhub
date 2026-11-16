import Foundation
import Testing
@testable import AgentApp

// P16 Part 5: in-flight work survives a quit, a crash or a failed write.

@MainActor @Test func tokenAppendsAutosaveTheIncompletePartial() async throws {
    let url = temporaryStore()
    let backend = TestBackend(streamMode: .longRunning)
    let store = AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.autosaveInterval = .zero
    let bot = Bot(name: "Saver", backend: .herdr, sessionID: "s"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go")
    try await waitUntil { (try? String(contentsOf: url, encoding: .utf8))?.contains("\"running\"") == true }
    let reloaded = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let reply = try #require(reloaded.bots.first?.messages.last)
    #expect(reply.content == "running" && reply.turnState == .incomplete)
    store.stop()
    try await waitUntil { !store.anyTurnRunning }
}

@MainActor @Test func aFailingSaveIsReportedOncePerStreak() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let directory = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    store.save()
    #expect(store.errorMessage?.hasPrefix("Could not save your chats") == true)
    store.errorMessage = nil; store.save()
    #expect(store.errorMessage == nil, "reported once per streak")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    store.save(); try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    store.save()
    #expect(store.errorMessage != nil, "a new streak reports again")
}

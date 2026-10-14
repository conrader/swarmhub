import Foundation
import Testing
@testable import AgentApp

// P16 Part 5: in-flight work survives a quit, a crash or a failed write.

@MainActor @Test func thePartialAndTheRoundAreOnDiskWhileAMemberAnswers() async throws {
    let url = temporaryStore()
    let (store, bots, states) = reconcileStore(bots: ["Alpha", "Beta"], url: url)
    store.autosaveInterval = .zero
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    states[0].with { $0.scripts = [.hang] }
    store.send(text: "work on it", to: group)
    try await waitUntil { states[0].chatPosts.count == 1 }
    // Placeholder birth and the round change were saved at once.
    let reloaded = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let copy = try #require(reloaded.groups.first)
    #expect(copy.round?.active == bots[0].id && copy.round?.remaining == [bots[1].id])
    #expect(copy.messages.first { $0.authorID == bots[0].id }?.turnState == .incomplete)
    store.stop()
    try await waitUntil { store.isIdle }
}

@MainActor @Test func tokenAppendsAutosaveTheIncompletePartial() async throws {
    let url = temporaryStore()
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning)
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.autosaveInterval = .zero
    let bot = Bot(name: "Saver", backend: .hermes, hermesSessionID: "s"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go")
    try await waitUntil { (try? String(contentsOf: url, encoding: .utf8))?.contains("\"running\"") == true }
    let reloaded = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let reply = try #require(reloaded.bots.first?.messages.last)
    #expect(reply.content == "running" && reply.turnState == .incomplete)
    store.stop()
    try await waitUntil { store.isIdle }
}

@MainActor @Test func launchRecoveryMarksMembersNotAskedAndSendsNothing() async throws {
    let url = temporaryStore()
    let (store, bots, states) = reconcileStore(bots: ["Alpha", "Beta", "Gamma"], url: url)
    let group = try #require(store.createGroup(name: "", memberIDs: bots.map(\.id)))
    let trigger = ChatMessage(role: .user, content: "before the quit"); group.messages.append(trigger)
    // Beta was active but has no row yet (treated as remaining); Gamma was never asked.
    group.round = GroupRound(userMessageID: trigger.id, remaining: [bots[2].id], active: bots[1].id)
    store.save()
    let relaunched = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: store.keyStore, defaults: isolatedDefaults(), hermesSession: store.hermesSession)
    relaunched.recoverInterruptedRounds()
    let copy = try #require(relaunched.groups.first)
    #expect(copy.round == nil)
    #expect(copy.messages.filter { $0.turnState == .notSent && $0.metadata["why"] == "quit" }.compactMap(\.authorID) == [bots[1].id, bots[2].id])
    #expect(copy.messages.last?.content == "\(AppConstants.name) quit before Beta, Gamma were asked. Retry on their rows.")
    #expect(states.allSatisfy { $0.posts.isEmpty })
}

@MainActor @Test func aFailingSaveIsReportedOncePerStreak() throws {
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
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

import Foundation
import Testing
@testable import AgentApp

@Test func backendKindsAreStable() {
    #expect(BackendKind.allCases.count == 3)
    #expect(BackendKind.hermes.rawValue == "Hermes Agent")
}

@Test func defaultHermesURLUsesV1() {
    #expect(AppConstants.defaultHermesURL.hasSuffix("/v1"))
}

@Test func hermesProfileAndSessionPersist() throws {
    let bot = Bot(name: "research", backend: .hermes, hermesProfile: "research", hermesSessionID: "session-1")
    let restored = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
    #expect(restored.hermesProfile == "research")
    #expect(restored.hermesSessionID == "session-1")
}

@Test func hermesRejectsRemotePlaintextAPIKeys() {
    #expect(HermesBackend.permitsAPIKey("secret", at: URL(string: "http://example.com/v1")!) == false)
    #expect(HermesBackend.permitsAPIKey("secret", at: URL(string: "http://127.0.0.1:8642/v1")!))
    #expect(HermesBackend.permitsAPIKey("secret", at: URL(string: "http://localhost:8642/v1")!))
    #expect(HermesBackend.permitsAPIKey("secret", at: URL(string: "https://example.com/v1")!))
    #expect(HermesBackend.permitsAPIKey("", at: URL(string: "http://example.com/v1")!))
}

@Test @MainActor func legacySendNeverCallsSessions() async throws {
    let backend = TestBackend(transport: .legacyChatCompletions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Legacy", backend: .hermes); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "hello")
    try await waitUntil { !store.anyTurnRunning }
    let calls = await backend.recordedCalls()
    #expect(calls.contains("send")); #expect(!calls.contains("create")); #expect(!calls.contains("list")); #expect(!calls.contains("history"))
    #expect(bot.hermesSessionID == nil)
}

@Test @MainActor func historyDoesNotAdoptForeignSession() async throws {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Unowned", backend: .hermes); store.bots = [bot]
    store.loadServerHistory(for: bot)
    try await backend.calls.wait { $0 == ["capabilities"] }
    #expect(await backend.recordedCalls() == ["capabilities"])
    #expect(bot.hermesSessionID == nil)
}

@Test @MainActor func historyMergeNeverShrinksAndPreservesLocalIdentity() {
    let old = ChatMessage(role: .user, content: "pre-Hermes", reactions: ["👍"])
    let localOnly = ChatMessage(role: .system, content: "Stop requested from Hermes.")
    let user = ChatMessage(role: .user, content: "new turn", replyToID: old.id)
    let assistant = ChatMessage(role: .assistant, content: "reply")
    let local = [old, localOnly, user, assistant]
    let server = [BackendMessage(role: "user", content: "new turn"), BackendMessage(role: "assistant", content: "reply"), BackendMessage(role: "user", content: "newer"), BackendMessage(role: "assistant", content: "answer")]
    let merged = AppStore.mergeHermesHistory(local: local, server: server)
    #expect(merged?.count == 6)
    #expect(merged?.prefix(4).map(\.id) == local.map(\.id))
    #expect(merged?[0].reactions == ["👍"]); #expect(merged?[2].replyToID == old.id)
    #expect(AppStore.mergeHermesHistory(local: local, server: []) == nil)
    #expect(AppStore.mergeHermesHistory(local: local, server: [.init(role: "user", content: "unrelated")]) == nil)
}

@Test @MainActor func historyMergeAcceptsMultimodalRowsWithoutReplacingLocalRows() {
    let user = ChatMessage(role: .user, content: "question")
    let merged = AppStore.mergeHermesHistory(local: [user], server: [
        .init(role: "user", content: "question"), .init(role: "assistant", content: "text\n[Image: https://example.test/a.png]")
    ])
    #expect(merged?.count == 2); #expect(merged?.first?.id == user.id)
}

@Test func hermesContentNormalizationDropsNullAndUnsupportedJSON() {
    #expect(HermesBackend.normalizedContent(NSNull()) == nil)
    #expect(HermesBackend.normalizedContent(42) == nil)
    #expect(HermesBackend.normalizedContent(true) == nil)
    #expect(HermesBackend.normalizedContent(["unexpected": "value"]) == nil)
    #expect(HermesBackend.normalizedContent(["text": "one object"]) == "one object")
}

@Test func historyPagingStopsAtTheConfiguredCap() async {
    let trace = LockedTrace()
    do {
        _ = try await HermesBackend.loadMessagePages(pageSize: 2, maximumPages: 3) { offset, _ in
            trace.add(String(offset))
            return ([BackendMessage(role: "user", content: "row-\(offset)"), BackendMessage(role: "assistant", content: "row-\(offset + 1)")], 2)
        }
        Issue.record("Expected the paging safety limit to throw")
    } catch {
        #expect(error.localizedDescription.contains("6-row paging safety limit"))
    }
    #expect(trace.read() == ["0", "2", "4"])
}

@Test @MainActor func historyMergeUsesLatestFullTurnPairOverlap() {
    let local = [ChatMessage(role: .user, content: "repeat"), ChatMessage(role: .assistant, content: "ok")]
    let server = [
        BackendMessage(role: "user", content: "repeat"), BackendMessage(role: "assistant", content: "ok"),
        BackendMessage(role: "user", content: "repeat"), BackendMessage(role: "assistant", content: "ok"),
        BackendMessage(role: "user", content: "new"), BackendMessage(role: "assistant", content: "answer")
    ]
    let merged = AppStore.mergeHermesHistory(local: local, server: server)
    #expect(merged?.map(\.content) == ["repeat", "ok", "new", "answer"])
    #expect(AppStore.mergeHermesHistory(local: local, server: [.init(role: "assistant", content: "ok")]) == nil)
}

@Test @MainActor func divergentHistoryAddsAQuietNote() async throws {
    let backend = TestBackend(transport: .nativeSessions, rows: [.init(role: "user", content: "different")])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "History", backend: .hermes, messages: [ChatMessage(role: .user, content: "local"), ChatMessage(role: .assistant, content: "partial")], hermesSessionID: "history-1")
    store.bots = [bot]; store.selectedBot = bot; store.loadServerHistory(for: bot)
    try await waitUntil { bot.messages.last?.content.contains("was not merged") == true }
    #expect(bot.messages.last?.role == .system)
}


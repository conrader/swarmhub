import Foundation
import Testing
@testable import AgentApp

@Test @MainActor func stopCapturesThenCancelsThenPostsOnlyOnce() async throws {
    let trace = LockedTrace()
    let backend = TestBackend(streamMode: .longRunning, stopTrace: trace)
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, didCancelLocalStream: { trace.add("cancel") }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Stop", backend: .herdr, sessionID: "session-1"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go"); try await backend.calls.wait { $0.contains("send") }
    store.stop(); store.stop()
    try await waitUntil { bot.messages.filter { $0.role == .system && $0.content.contains("Stop requested") }.count == 1 }
    let stopCalls = await backend.recordedCalls().filter { ["capture", "post"].contains($0) }
    #expect(stopCalls == ["capture", "post"]); #expect(trace.read() == ["cancel", "post"])
    #expect(bot.messages.filter { $0.role == .system && $0.content.contains("Stop requested") }.count == 1)
}

@Test @MainActor func anOlderStopRequestDoesNotBlockStoppingTheNextRun() async throws {
    let trace = LockedTrace()
    let backend = TestBackend(streamMode: .longRunning, stopTrace: trace, stopDelay: .milliseconds(400))
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, didCancelLocalStream: { trace.add("cancel") }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Stop twice", backend: .herdr, sessionID: "session-2"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await backend.calls.wait { $0.contains("send") }; store.stop()
    try await waitUntil { !store.anyTurnRunning }
    store.send(text: "second"); try await backend.calls.wait { $0.filter { $0 == "send" }.count == 2 }; store.stop()
    try await backend.calls.wait { $0.filter { $0 == "post" }.count == 2 }; try await waitUntil { !store.anyTurnRunning }

    #expect(trace.read() == ["cancel", "post", "cancel", "post"])
    #expect(await backend.recordedCalls().filter { $0 == "post" }.count == 2)
}

@Test @MainActor func failedOldStopDoesNotClearOrReportAgainstNewerRun() async throws {
    let backend = TestBackend(streamMode: .longRunning, stopDelay: .milliseconds(300), failingStopCalls: [1])
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Stop race", backend: .herdr, sessionID: "session-race"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await backend.calls.wait { $0.contains("send") }; store.stop()
    try await waitUntil { !store.anyTurnRunning }
    store.send(text: "second"); try await backend.calls.wait { $0.filter { $0 == "send" }.count == 2 }
    try await backend.calls.wait { $0.contains("post-failed") }
    // The mock records the failure before throwing it; the store reports it once the throw reaches it.
    try await waitUntil { bot.messages.contains { $0.role == .system && $0.content.contains("Herdr Stop failed") } }

    #expect(store.anyTurnRunning)
    #expect(store.errorMessage == nil)
    #expect(bot.messages.dropLast(2).contains { $0.role == .system && $0.content.contains("Herdr Stop failed") })
    store.stop()
    try await waitUntil { !store.anyTurnRunning }
}

@Test @MainActor func failedCurrentStopIsReportedBesideStoppedTurn() async throws {
    let backend = TestBackend(streamMode: .longRunning, failingStopCalls: [1])
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Stop failure", backend: .herdr, sessionID: "session-failure"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await backend.calls.wait { $0.contains("send") }
    let stoppedAssistantID = bot.messages.last?.id
    store.stop()
    let laterMessage = ChatMessage(role: .system, content: "Later local message")
    bot.messages.append(laterMessage)
    try await waitUntil { bot.messages.contains { $0.role == .system && $0.content.contains("Herdr Stop failed") } }

    let stoppedIndex = try #require(bot.messages.firstIndex { $0.id == stoppedAssistantID })
    let noteIndex = try #require(bot.messages.firstIndex { $0.role == .system && $0.content.contains("Herdr Stop failed") })
    let laterIndex = try #require(bot.messages.firstIndex { $0.id == laterMessage.id })
    let stopped = bot.messages[stoppedIndex]
    #expect(stopped.stopUnconfirmed && store.needsAttention(bot))
    #expect(TurnStateFooter.text(for: stopped) == "Stop unconfirmed. The bot may still be running.")
    #expect(noteIndex == stoppedIndex + 1)
    #expect(laterIndex == noteIndex + 1)
}

@Test @MainActor func legacyDemoBotsAreMigratedAndHiddenOnceAServerIsSetUp() throws {
    let defaults = isolatedDefaults(); defaults.set("http://127.0.0.1:8787", forKey: HerdrServerList.legacyAddressKey)
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bot = Bot(name: "Atlas", backend: .mock)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode([bot])) as! [[String: Any]]
    json[0].removeValue(forKey: "isDemo"); try JSONSerialization.data(withJSONObject: json).write(to: url)
    let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.bots.first?.isDemo == true); #expect(store.bots.first?.isHidden == true)
}

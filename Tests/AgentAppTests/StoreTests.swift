import Foundation
import Testing
@testable import AgentApp

@Test @MainActor func newBotApprovalSettingsPersist() throws {
    let url = temporaryStore()
    let reviewer = Bot(name: "Reviewer")
    let rules = [ApprovalRule(name: "Only status", actionPattern: "command", commandPattern: "git status", outcome: .allow)]
    let store = AppStore(storeURL: url, autoConfigureHermes: false)
    store.bots = [reviewer]
    store.addBot(name: "New", persona: "Review carefully", backend: .hermes, avatarName: .faceSky, approvalMode: .reviewer, approvalRules: rules, reviewerBotID: reviewer.id)
    let restored = AppStore(storeURL: url, autoConfigureHermes: false)
    let bot = try #require(restored.bots.first { $0.name == "New" })
    #expect(bot.approvalMode == .reviewer); #expect(bot.approvalRules == rules); #expect(bot.reviewerBotID == reviewer.id)
}

@Test @MainActor func stopCapturesThenCancelsThenPostsOnlyOnce() async throws {
    let trace = LockedTrace()
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning, stopTrace: trace)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, didCancelLocalStream: { trace.add("cancel") })
    let bot = Bot(name: "Stop", backend: .hermes, hermesSessionID: "session-1"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go"); try await waitUntil { await backend.recordedCalls().contains("send") }
    store.stop(); store.stop()
    try await waitUntil { bot.messages.filter { $0.role == .system && $0.content.contains("Stop requested") }.count == 1 }
    let stopCalls = await backend.recordedCalls().filter { ["capture", "post"].contains($0) }
    #expect(stopCalls == ["capture", "post"]); #expect(trace.read() == ["cancel", "post"])
    #expect(bot.messages.filter { $0.role == .system && $0.content.contains("Stop requested") }.count == 1)
}

@Test @MainActor func anOlderStopRequestDoesNotBlockStoppingTheNextRun() async throws {
    let trace = LockedTrace()
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning, stopTrace: trace, stopDelay: .milliseconds(400))
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, didCancelLocalStream: { trace.add("cancel") })
    let bot = Bot(name: "Stop twice", backend: .hermes, hermesSessionID: "session-2"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await waitUntil { await backend.recordedCalls().contains("send") }; store.stop()
    try await waitUntil { store.isIdle }
    store.send(text: "second"); try await waitUntil { await backend.recordedCalls().filter { $0 == "send" }.count == 2 }; store.stop()
    try await waitUntil { await backend.recordedCalls().filter { $0 == "post" }.count == 2 && !store.isStreaming }

    #expect(trace.read() == ["cancel", "post", "cancel", "post"])
    #expect(await backend.recordedCalls().filter { $0 == "post" }.count == 2)
}

@Test @MainActor func failedOldStopDoesNotClearOrReportAgainstNewerRun() async throws {
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning, stopDelay: .milliseconds(300), failingStopCalls: [1])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Stop race", backend: .hermes, hermesSessionID: "session-race"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await waitUntil { await backend.recordedCalls().contains("send") }; store.stop()
    try await waitUntil { store.isIdle }
    store.send(text: "second"); try await waitUntil { await backend.recordedCalls().filter { $0 == "send" }.count == 2 }
    try await waitUntil { await backend.recordedCalls().contains("post-failed") }

    #expect(store.isStreaming)
    #expect(store.errorMessage == nil)
    #expect(bot.messages.dropLast(2).contains { $0.role == .system && $0.content.contains("Hermes Stop failed") })
    store.stop()
    try await waitUntil { !store.isStreaming }
}

@Test @MainActor func failedCurrentStopIsReportedBesideStoppedTurn() async throws {
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning, failingStopCalls: [1])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Stop failure", backend: .hermes, hermesSessionID: "session-failure"); store.bots = [bot]; store.selectedBot = bot

    store.send(text: "first"); try await waitUntil { await backend.recordedCalls().contains("send") }
    let stoppedAssistantID = bot.messages.last?.id
    store.stop()
    let laterMessage = ChatMessage(role: .system, content: "Later local message")
    bot.messages.append(laterMessage)
    try await waitUntil { bot.messages.contains { $0.role == .system && $0.content.contains("Hermes Stop failed") } }

    let stoppedIndex = try #require(bot.messages.firstIndex { $0.id == stoppedAssistantID })
    let noteIndex = try #require(bot.messages.firstIndex { $0.role == .system && $0.content.contains("Hermes Stop failed") })
    let laterIndex = try #require(bot.messages.firstIndex { $0.id == laterMessage.id })
    #expect(noteIndex == stoppedIndex + 1)
    #expect(laterIndex == noteIndex + 1)
}

@Test @MainActor func legacyDemoBotsAreMigratedAndHiddenWhenHermesConfigured() throws {
    let key = "hermesBaseURL"; let previous = UserDefaults.standard.object(forKey: key)
    defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    UserDefaults.standard.set("http://127.0.0.1:8642/v1", forKey: key)
    let url = temporaryStore(); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bot = Bot(name: "Atlas", backend: .mock)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode([bot])) as! [[String: Any]]
    json[0].removeValue(forKey: "isDemo"); try JSONSerialization.data(withJSONObject: json).write(to: url)
    let store = AppStore(storeURL: url, autoConfigureHermes: false)
    #expect(store.bots.first?.isDemo == true); #expect(store.bots.first?.isHidden == true)
}

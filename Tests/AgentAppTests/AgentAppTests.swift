import Foundation
import Testing
@testable import AgentApp

private actor TestBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    enum StreamMode { case reply, approvalThenFinish, longRunning }
    let transportValue: HermesTransport
    let rows: [BackendMessage]
    let streamMode: StreamMode
    nonisolated let stopTrace: LockedTrace?
    let stopDelay: Duration
    let failingStopCalls: Set<Int>
    private(set) var calls: [String] = []
    init(transport: HermesTransport, rows: [BackendMessage] = [], streamMode: StreamMode = .reply, stopTrace: LockedTrace? = nil, stopDelay: Duration = .milliseconds(80), failingStopCalls: Set<Int> = []) {
        transportValue = transport; self.rows = rows; self.streamMode = streamMode; self.stopTrace = stopTrace; self.stopDelay = stopDelay; self.failingStopCalls = failingStopCalls
    }
    func sessionTransport() async throws -> HermesTransport? { calls.append("capabilities"); return transportValue }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        calls.append("send")
        return AsyncThrowingStream { continuation in
            let mode = streamMode
            let task = Task {
                switch mode {
                case .reply:
                    continuation.yield(.token("ok")); continuation.yield(.completed)
                case .approvalThenFinish:
                    continuation.yield(.approval(.init(id: UUID(), title: "Approve", summary: "cmd", draft: nil, command: "cmd", runID: "run-1", requestID: "req-1")))
                    try? await Task.sleep(for: .milliseconds(180)); continuation.yield(.completed)
                case .longRunning:
                    continuation.yield(.token("running")); try? await Task.sleep(for: .seconds(10))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { calls.append("list"); return [.init(id: "foreign", title: "Foreign")] }
    func loadMessages(sessionID: String) async throws -> [BackendMessage] { calls.append("history"); return rows }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { calls.append("create"); return id! }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func stopTarget(sessionID: String) async throws -> StopTarget { calls.append("capture"); return .serverRun("run-1") }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        stopTrace?.add("post"); let callNumber = calls.filter { $0 == "post" }.count + 1; calls.append("post")
        try? await Task.sleep(for: stopDelay)
        if failingStopCalls.contains(callNumber) { calls.append("post-failed"); throw BackendError.unavailable("old stop failed") }
        return .requested
    }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func resolveApproval(_ approval: ApprovalRequest, approved: Bool) async throws { calls.append("approval") }
    func testConnection() async throws -> String { "ok" }
    func recordedCalls() -> [String] { calls }
}

private final class LockedTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private func temporaryStore(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(name)/store.json")
}

private struct WaitTimeout: Error {}

@MainActor private func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    throw WaitTimeout()
}

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

@Test func approvalKeepsHermesRunIdentity() throws {
    let botID = UUID()
    let value = ApprovalRequest(id: UUID(), title: "Approve", summary: "command", draft: nil, command: "command", runID: "run-1", requestID: "req-1", botID: botID, profile: "research", sessionID: "session-1")
    let restored = try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(value))
    #expect(restored.runID == "run-1")
    #expect(restored.requestID == "req-1")
    #expect(restored.botID == botID)
    #expect(restored.profile == "research")
    #expect(restored.sessionID == "session-1")
    #expect(restored.hasKnownCommand)
    #expect(!ApprovalRequest(id: UUID(), title: "Unknown", summary: "Command unknown", draft: nil).hasKnownCommand)
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
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Legacy", backend: .hermes); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "hello")
    try await waitUntil { !store.isStreaming }
    let calls = await backend.recordedCalls()
    #expect(calls.contains("send")); #expect(!calls.contains("create")); #expect(!calls.contains("list")); #expect(!calls.contains("history"))
    #expect(bot.hermesSessionID == nil)
}

@Test @MainActor func historyDoesNotAdoptForeignSession() async throws {
    let backend = TestBackend(transport: .nativeSessions)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "Unowned", backend: .hermes); store.bots = [bot]
    store.loadHermesHistory(for: bot)
    try await waitUntil { await backend.recordedCalls() == ["capabilities"] }
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
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let bot = Bot(name: "History", backend: .hermes, messages: [ChatMessage(role: .user, content: "local"), ChatMessage(role: .assistant, content: "partial")], hermesSessionID: "history-1")
    store.bots = [bot]; store.selectedBot = bot; store.loadHermesHistory(for: bot)
    try await waitUntil { bot.messages.last?.content.contains("was not merged") == true }
    #expect(bot.messages.last?.role == .system)
}

@Test @MainActor func stopCapturesThenCancelsThenPostsOnlyOnce() async throws {
    let trace = LockedTrace()
    let backend = TestBackend(transport: .nativeSessions, streamMode: .longRunning, stopTrace: trace)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, didCancelLocalStream: { trace.add("cancel") })
    let bot = Bot(name: "Stop", backend: .hermes, hermesSessionID: "session-1"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go"); try await waitUntil { await backend.recordedCalls().contains("send") }
    store.stop(); store.stop()
    try await waitUntil { await backend.recordedCalls().filter { $0 == "post" }.count == 1 && !store.isStreaming }
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
    try await waitUntil { !store.isStreaming }
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
    try await waitUntil { !store.isStreaming }
    store.send(text: "second"); try await waitUntil { await backend.recordedCalls().filter { $0 == "send" }.count == 2 }
    try await waitUntil { await backend.recordedCalls().contains("post-failed") }

    #expect(store.isStreaming)
    #expect(store.errorMessage == nil)
    store.stop()
    try await waitUntil { !store.isStreaming }
}

@Test @MainActor func approvalIsScopedAndClearedAtRunEnd() async throws {
    let backend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend })
    let first = Bot(name: "First", backend: .hermes, hermesProfile: "research", hermesSessionID: "s1")
    let second = Bot(name: "Second", backend: .hermes, hermesSessionID: "s2")
    store.bots = [first, second]; store.selectedBot = first; store.send(text: "go")
    try await waitUntil { store.approvals.count == 1 }
    #expect(store.approvals.count == 1); #expect(store.approvals.first?.botID == first.id)
    #expect(store.approvals.first?.profile == "research"); #expect(store.approvals.first?.sessionID == "s1")
    try await waitUntil { store.approvals.isEmpty }; #expect(store.approvals.isEmpty)
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

import Combine
import Foundation
import Testing
@testable import AgentApp

@Test func textArrivalToolsAndPausesSelectDistinctPhases() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    #expect(ChatActivityPhase.current(nil, lastText: nil, now: start) == .thinking)
    #expect(ChatActivityPhase.current(nil, lastText: start, now: start.addingTimeInterval(1)) == .typing)
    #expect(ChatActivityPhase.current(nil, lastText: start, now: start.addingTimeInterval(3)) == .thinking)

    var activity = ToolActivity()
    activity.apply(.init(phase: .started, name: "execute_code"), at: start.addingTimeInterval(4))
    #expect(ChatActivityPhase.current(activity, lastText: start.addingTimeInterval(3), now: start.addingTimeInterval(4)) == .working,
            "A new tool start supersedes the preceding text.")
    activity.apply(.init(phase: .completed, name: "execute_code"), at: start.addingTimeInterval(4.5))
    #expect(ChatActivityPhase.current(activity, lastText: start.addingTimeInterval(3), now: start.addingTimeInterval(4.5)) == .thinking,
            "After the tool finishes, wait for new model output.")
    #expect(ChatActivityPhase.current(activity, lastText: start.addingTimeInterval(5), now: start.addingTimeInterval(5)) == .typing)
    #expect(ChatActivityPhase.current(activity, lastText: start.addingTimeInterval(5), now: start.addingTimeInterval(8)) == .thinking)
}

@Test func concurrentToolsRemainWorkingUntilAllFinishAndInternalThinkingIsNotWork() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    activity.apply(.init(phase: .progress, name: "_thinking"), at: start)
    #expect(ChatActivityPhase.current(activity, lastText: nil, now: start) == .thinking)
    activity.apply(.init(phase: .started, name: "read_file", callID: "a"), at: start)
    activity.apply(.init(phase: .started, name: "web_search", callID: "b"), at: start)
    activity.apply(.init(phase: .failed, name: "web_search", callID: "b"), at: start.addingTimeInterval(1))
    #expect(ChatActivityPhase.current(activity, lastText: nil, now: start.addingTimeInterval(1)) == .working)
    activity.apply(.init(phase: .completed, name: "read_file", callID: "a"), at: start.addingTimeInterval(2))
    #expect(ChatActivityPhase.current(activity, lastText: nil, now: start.addingTimeInterval(2)) == .thinking)
}

@Test @MainActor func botThreadAndGroupSidebarUseTheSameReplyPhase() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Fixture")
    let group = GroupChat(name: "Team", memberIDs: [bot.id])
    let assistant = ChatMessage(role: .assistant, content: "", createdAt: start, isStreaming: true)
    store.streamingBotID = bot.id; store.streamingAssistant = assistant; store.streamingConversation = group; store.isStreaming = true
    #expect(store.workingLine(for: bot, now: start) == "Thinking…")
    #expect(store.workingLine(for: group, now: start) == "Thinking…")
    assistant.lastTextAt = start
    #expect(store.workingLine(for: bot, now: start) == "Typing…")
    #expect(store.workingLine(for: group, now: start) == "Typing…")
    #expect(store.workingLine(for: group, now: start.addingTimeInterval(3)) == "Thinking…")
    let thread = ChatThread(parentMessageID: UUID(), parentSessionID: "parent", hermesSessionID: "thread", messages: [assistant])
    store.streamingConversation = thread
    #expect(store.workingLine(for: bot, now: start) == "Typing…")
    #expect(store.workingLine(for: group, now: start) == nil)
    assistant.isStreaming = false
    #expect(store.workingLine(for: bot, now: start) == nil)
}

@Test @MainActor func streamEventsDriveActivityAndEmptyChunksDoNotClaimTyping() async throws {
    let backend = PhaseFixtureBackend()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Fixture", backend: .hermes, hermesSessionID: "synthetic-phase")
    store.bots = [bot]; store.selectedBot = bot
    #expect(store.send(text: "Test")); defer { store.stop() }
    try await waitUntil { await backend.ready }
    let assistant = try #require(store.streamingAssistant)
    #expect(store.workingLine(for: bot) == "Thinking…")
    await backend.emit(.token("")); await backend.emit(.status("empty chunk consumed"))
    try await waitUntil { assistant.metadata["status"] == "empty chunk consumed" }
    #expect(assistant.lastTextAt == nil && store.workingLine(for: bot) == "Thinking…")
    let changes = LockedTrace()
    let subscription = store.objectWillChange.sink { changes.add("change") }
    await backend.emit(.tool(.init(phase: .started, name: "read_file")))
    try await waitUntil { assistant.activity?.current != nil }
    #expect(store.workingLine(for: bot)?.hasPrefix("Working…") == true)
    #expect(!changes.read().isEmpty, "Tool events must refresh the sidebar immediately.")
    await backend.emit(.tool(.init(phase: .completed, name: "read_file")))
    try await waitUntil { assistant.activity?.current == nil }
    #expect(store.workingLine(for: bot) == "Thinking…")
    await backend.emit(.token("Reply text"))
    try await waitUntil { assistant.content == "Reply text" }
    #expect(store.workingLine(for: bot) == "Typing…")
    await backend.emit(.tool(.init(phase: .progress, name: "_thinking")))
    try await waitUntil { assistant.lastTextAt == nil }
    #expect(store.workingLine(for: bot) == "Thinking…", "An explicit reasoning event ends the Typing phase immediately.")
    await backend.emit(.token(" again"))
    try await waitUntil { assistant.content == "Reply text again" }
    #expect(store.workingLine(for: bot) == "Typing…")
    await backend.emit(.replace(""))
    try await waitUntil { assistant.content.isEmpty }
    #expect(assistant.lastTextAt == nil && store.workingLine(for: bot) == "Thinking…")
    await backend.finish()
    try await waitUntil { store.isIdle }
    #expect(store.workingLine(for: bot) == nil)
    withExtendedLifetime(subscription) {}
}

private actor PhaseFixtureBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    private var continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation?
    var ready: Bool { continuation != nil }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let pair = AsyncThrowingStream<AgentEvent, Error>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func emit(_ event: AgentEvent) { continuation?.yield(event) }
    func finish() { continuation?.yield(.completed); continuation?.finish(); continuation = nil }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "Synthetic" }
}

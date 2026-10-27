import Foundation
import Testing
@testable import AgentApp

/// P28: a backend whose streams the test drives event by event; records send, steer and stop calls in order.
actor ScriptedTurnBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    nonisolated let calls = AwaitableLog<String>()
    private var streams: [AsyncThrowingStream<AgentEvent, Error>.Continuation] = []
    private let stopFails: Bool, steerFails: Bool, steerless: Bool
    /// `steerless`: a runtime without `run_steer` (uxfix1: a message typed during its turn waits for the turn to end).
    init(stopFails: Bool = false, steerFails: Bool = false, steerless: Bool = false) { self.stopFails = stopFails; self.steerFails = steerFails; self.steerless = steerless }

    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func features() async throws -> Set<String> { steerless ? ["session_chat_streaming"] : ["session_chat_streaming", "run_steer"] }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AgentEvent.self)
        streams.append(continuation)
        calls.append("send:\(request.messages.last?.content ?? "")")
        return stream
    }
    func steer(sessionID: String, text: String) async throws {
        if steerFails { calls.append("steer-failed:\(text)"); throw BackendError.http(409, "no run to steer") }
        calls.append("steer:\(text)")
    }
    func stopTarget(sessionID: String) async throws -> StopTarget { .serverRun("run-\(streams.count)") }
    func requestStop(_ target: StopTarget) async throws -> StopOutcome {
        if stopFails { calls.append("stop-failed"); throw BackendError.http(500, "stop broke") }
        if case .serverRun(let run) = target { calls.append("stop:\(run)") }
        return .requested
    }
    func createSession(title: String, systemPrompt: String, id: String?) async throws -> String { id ?? "s" }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "ok" }

    /// Yields to the newest stream (or stream `index`, 1-based).
    func emit(_ events: AgentEvent..., stream index: Int? = nil) {
        let continuation = streams[(index ?? streams.count) - 1]
        events.forEach { continuation.yield($0) }
    }
    func end(stream index: Int? = nil) { streams[(index ?? streams.count) - 1].finish() }
    var streamCount: Int { streams.count }
}

@MainActor func steerStore(_ backend: ScriptedTurnBackend, url: URL = temporaryStore()) -> (AppStore, Bot) {
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let bot = Bot(name: "Steer", backend: .hermes, hermesProfile: "default", hermesSessionID: "session-steer")
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot)
}

func step(_ phase: ToolEvent.Phase, _ name: String = "terminal", id: String = "c1") -> AgentEvent { .tool(ToolEvent(phase: phase, name: name, callID: id)) }

/// Sends `text`, streams "Before. " (and a running step when `step`), and waits until the turn can be steered.
@MainActor func startSteerableTurn(_ store: AppStore, _ backend: ScriptedTurnBackend, _ text: String = "go", running: Bool) async throws {
    #expect(store.send(text: text))
    try await backend.calls.wait { $0.contains("send:\(text)") }
    await backend.emit(.token("Before. "))
    if running { await backend.emit(step(.started)) }
    let steers = await backend.features().contains("run_steer")
    try await waitUntil { (store.soleTurn?.steerAvailable == steers) && store.soleTurn?.assistant?.content == "Before. " && (store.soleTurn?.assistant?.activity?.current != nil) == running }
}

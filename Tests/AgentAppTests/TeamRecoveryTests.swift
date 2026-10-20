import Foundation
import Testing
import SwarmHubCoordination
@testable import AgentApp

actor TeamRecoveryBackend: AgentBackend {
    nonisolated let kind = BackendKind.hermes
    var sends: [(String, String)] = []
    var finished = false
    func sessionTransport() async throws -> HermesTransport? { .nativeSessions }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        sends.append((request.sessionID, request.messages.first?.content ?? ""))
        let first = sends.count == 1
        return AsyncThrowingStream { continuation in
            if !first { continuation.yield(.token("Consolidated result")); continuation.yield(.completed) }
            continuation.finish()
        }
    }
    func finishRemote() { finished = true }
    func loadMessages(sessionID: String) async throws -> [BackendMessage] {
        guard finished, let sent = sends.first, sent.0 == sessionID else { return [] }
        return [.init(id: 1, role: "user", content: sent.1, createdAt: .now),
                .init(id: 2, role: "assistant", content: "Remote task completed", createdAt: .now, finishReason: "stop")]
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { Issue.record("Recovery must not call Stop"); return .requested }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "synthetic" }
    func count() -> Int { sends.count }
}

@MainActor struct TeamRecoveryTests {
    func fixture(_ backend: any AgentBackend) -> (AppStore, Bot, Bot) {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.reconcileTiming.schedule = []
        let author = Bot(name: "Jarvis fixture", backend: .hermes, hermesProfile: "author")
        let peer = Bot(name: "Infra fixture", backend: .hermes, hermesProfile: "peer")
        store.bots = [author, peer]; return (store, author, peer)
    }

    @Test func recoveryReadsRemoteCompletionAndSendsOnlyTheNextTask() async throws {
        let backend = TeamRecoveryBackend(); let (store, author, peer) = fixture(backend)
        #expect(store.startTeamRequest("Inspect fixture", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        let id = try #require(store.workflows.keys.first)
        try await waitUntil { !store.anyTurnRunning }
        #expect(store.workflows[id]?.tasks[0].delivery?.state == .uncertain)
        await store.recoverTeams()
        #expect(await backend.count() == 1, "Missing history cannot justify a resend")
        let workflow = try #require(store.workflows[id])
        let task = try #require(store.workflows[id]?.tasks[0])
        #expect(!store.canReassignWorkflowTask(workflow, task: task))
        await backend.finishRemote()
        await store.recoverTeams()
        try await waitUntil { store.workflows[id]?.state == .completed }
        #expect(await backend.count() == 2)
        #expect(author.messages.filter { $0.metadata["workflowResultID"] != nil }.count == 1)
        await store.recoverTeams()
        #expect(await backend.count() == 2)
    }

    @Test func aFailedIntentCommitSendsNothing() {
        let backend = ScriptedTurnBackend(); let (store, author, peer) = fixture(backend)
        store.runtime = RejectingRuntime()
        #expect(!store.startTeamRequest("Inspect fixture", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        #expect(backend.calls.all.isEmpty && store.workflows.isEmpty && author.messages.isEmpty)
    }

    @Test func pauseAndCancelQueuedWorkNeverSendStop() async throws {
        let backend = ScriptedTurnBackend(); let (store, author, peer) = fixture(backend)
        #expect(store.startTeamRequest("Inspect fixture", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        try await backend.calls.wait { $0.contains { $0.hasPrefix("send:") } }
        let id = try #require(store.workflows.keys.first)
        store.pauseWorkflow(id); store.cancelQueuedTeamWork(id)
        #expect(!backend.calls.all.contains { $0.hasPrefix("stop:") })
        #expect(store.workflows[id]?.tasks[1].state == .cancelled)
        await backend.emit(.token("Done"), .completed); await backend.end()
        try await waitUntil { !store.anyTurnRunning }
        #expect(await backend.streamCount == 1)
    }

    @Test func ledgerRoundTripRetainsPolicyFactsAndPendingWork() throws {
        let backend = ScriptedTurnBackend(); let (store, author, peer) = fixture(backend)
        store.turns.pathDown = true
        #expect(store.startTeamRequest("Inspect fixture", origin: author, coordinator: author, recipient: peer, roster: [author, peer]))
        let saved = try #require(store.workflows.values.first)
        let records = try store.journal().records(Workflow.self, kind: AppStore.workflowKind)
        #expect(records == ([saved] as [Workflow]))
        #expect(saved.coordination?.policy.ownerDeviceID == store.teamDeviceID)
        #expect(saved.tasks.allSatisfy { $0.state == .queued })
    }
}

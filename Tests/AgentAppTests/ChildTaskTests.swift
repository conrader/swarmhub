import Foundation
import Testing
@testable import AgentApp

@MainActor struct ChildTaskTests {
    @Test func childStartAndFinishHaveOneIdentity() {
        var correlation = ChildTaskCorrelation(scope: "session-a")
        let start = correlation.event("subagent.start", ["task_id": "child", "task": "Research"])
        let end = correlation.event("subagent.complete", ["task_id": "child", "task": "Research", "status": "completed", "child_session_id": "child-1"])
        #expect(start.id == end.id && start.status == .running && end.status == .completed && end.sessionID == "child-1")
        var again = ChildTaskCorrelation(scope: "session-a")
        #expect(again.event("subagent.complete", ["task_id": "child"]).id == start.id, "a reconnect keeps the card")
        var other = ChildTaskCorrelation(scope: "session-b")
        #expect(other.event("subagent.start", ["task_id": "child"]).id != start.id)
    }

    @Test func eventsWithoutAnIDMatchTheOnlyWaitingStart() {
        var correlation = ChildTaskCorrelation()
        // Hermes 0.21.7 (fixture): the start has no id, the finish names a delegation.
        let start = correlation.event("subagent.start", ["run_id": "run_fixture", "task": "Research", "profile": "research"])
        let end = correlation.event("subagent.complete", ["task": "Research", "status": "completed", "summary": "done", "child_session_id": "child-1", "delegation_id": "deleg-1"])
        #expect(start.id == end.id && end.detail == "done")
        let a = correlation.event("subagent.start", ["task": "A"]), b = correlation.event("subagent.start", ["task": "B"])
        #expect(correlation.event("subagent.complete", ["task": "B", "status": "failed"]).id == b.id)
        #expect(correlation.event("subagent.complete", ["task": "anything"]).id == a.id)
        let x = correlation.event("subagent.start", ["task": "Same"]); _ = correlation.event("subagent.start", ["task": "Same"])
        #expect(correlation.event("subagent.complete", ["task": "Same"]).id != x.id, "two equal waiting starts are not guessed")
    }

    @Test func oneCardPerChildAndTheLedgerKeepsItAcrossRelaunch() throws {
        let url = temporaryStore()
        let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Lead", backend: .hermes); store.bots = [bot]
        let id = UUID()
        store.upsertSubAgent(.init(id: id, title: "Research", detail: "research", status: .running, runID: "child-run"), bot: bot, in: bot)
        store.upsertSubAgent(.init(id: id, title: "Research", detail: "done", status: .completed, sessionID: "child-1"), bot: bot, in: bot)
        store.upsertSubAgent(.init(id: id, title: "Research", detail: "late start", status: .running), bot: bot, in: bot)
        #expect(bot.messages.count == 1 && bot.messages[0].metadata["status"] == "completed" && bot.messages[0].metadata["detail"] == "done")
        let task = try #require(store.childTask(for: bot.messages[0])).task
        #expect(task.sessionID == "child-1" && task.runID == "child-run")
        store.save()
        let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let card = try #require(reopened.bots.first?.messages.first)
        let restored = try #require(reopened.childTask(for: card))
        #expect(restored.task.status == .completed && restored.task.sessionID == "child-1")
    }

    @Test func transcriptReadsTheChildSessionAndStopNeedsANamedRun() async throws {
        let backend = TestBackend(transport: .nativeSessions, rows: [.init(role: "assistant", content: "Child answer")])
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Lead", backend: .hermes); store.bots = [bot]
        let named = SubAgentTask(id: UUID(), title: "Child", detail: "", status: .running, sessionID: "child-1", runID: "child-run")
        #expect(try await store.childTranscript(named, bot: bot) == "assistant: Child answer")
        #expect(await store.canStopChild(named, bot: bot))
        #expect(!(await store.canStopChild(SubAgentTask(id: UUID(), title: "Child", detail: "", status: .running), bot: bot)))
        _ = try await store.stopChild(named, bot: bot)
        #expect(await backend.recordedCalls().contains("post:child-run"))
        await #expect(throws: (any Error).self) { try await store.childTranscript(SubAgentTask(id: UUID(), title: "Child", detail: "", status: .running), bot: bot) }
    }
}

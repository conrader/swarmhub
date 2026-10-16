import Foundation
import Testing
@testable import AgentApp

@MainActor struct TeamParallelTests {
    @Test func independentTasksUseExistingCapsAndKeepTheirSessionsSeparate() async throws {
        let backend = ScriptedTurnBackend(); let (store, author, peer) = TeamRecoveryTests().fixture(backend)
        let group = GroupChat(name: "Team", memberIDs: [author.id, peer.id]); store.groups = [group]
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: author.id, request: "Compare two independent fixtures", state: .paused,
            tasks: [.init(id: "first", botID: peer.id, instructions: "Inspect first", expectedOutput: "Evidence", dependencies: []),
                    .init(id: "second", botID: peer.id, instructions: "Inspect second", expectedOutput: "Evidence", dependencies: []),
                    .init(id: "final", botID: author.id, instructions: "Consolidate", expectedOutput: "Answer", dependencies: ["first", "second"])],
            budget: .init(id: UUID(), tokenLimit: 64_000))
        try store.saveWorkflow(workflow); store.authorizeTeamWorkflow(workflow.id)
        store.editTeam(workflow.id) { $0.limits.parallelTasks = 2 }
        store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 2 }
        let sent = try #require(store.workflows[workflow.id])
        #expect(sent.tasks[0].delivery?.sessionID != sent.tasks[1].delivery?.sessionID)
        #expect(sent.tasks[2].state == .queued)
        store.pauseWorkflow(workflow.id)
        await backend.emit(.token("First result"), .completed, stream: 1); await backend.end(stream: 1)
        await backend.emit(.token("Second result"), .completed, stream: 2); await backend.end(stream: 2)
        try await waitUntil { !store.anyTurnRunning }
        #expect(await backend.streamCount == 2)
        #expect(store.workflows[workflow.id]?.tasks[2].state == .queued)
    }
}

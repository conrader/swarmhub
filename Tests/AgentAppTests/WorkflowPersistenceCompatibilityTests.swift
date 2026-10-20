import Foundation
import Testing
import SwarmHubCoordination
@testable import AgentApp

@MainActor struct WorkflowPersistenceCompatibilityTests {
    // The P6b3 synthesized Codable form, before the rollback-compatible encoder.
    static let p6b3 = Data(#"""
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "groupID":"00000000-0000-0000-0000-000000000002",
      "coordinatorID":"00000000-0000-0000-0000-000000000003",
      "request":"Review TEST findings", "createdAt":123, "state":"paused",
      "tasks":[{
        "id":"review", "botID":"00000000-0000-0000-0000-000000000003",
        "instructions":"Review TEST work", "expectedOutput":"Findings", "dependencies":[],
        "role":"conversation", "state":"awaitingUserAcceptance",
        "threadID":"00000000-0000-0000-0000-000000000004",
        "result":"Findings for the user", "reservation":0, "chargedTokens":42,
        "reviewTargetID":"source", "reviewRootID":"source", "reviewRound":1,
        "completionConfirmed":true,
        "evidence":[{"source":"TEST log", "observation":"Checks passed"}]
      }],
      "budget":{"id":"00000000-0000-0000-0000-000000000005",
                "tokenLimit":64000, "reserved":0, "spent":42}
    }
    """#.utf8)

    // The old enum and the old decoder's fields that gate settling, reassignment, evidence and Resume.
    struct OldWorkflow: Decodable {
        struct Task: Decodable {
            enum State: String, Codable { case queued, running, completed, blocked, cancelled }
            var id: String
            var state: State
            var completionConfirmed: Bool?
            var reviewBlock: String?
            var reviewAcceptedByUser: Bool?
            var result: String?
            var error: String?
        }
        var id: UUID
        var state: Workflow.State
        var tasks: [Task]
    }

    @Test func readsP6b3AndRoundTripsTheNewFormWithoutLosingFindings() throws {
        let workflow = try JSONDecoder().decode(Workflow.self, from: Self.p6b3)
        #expect(workflow.awaitsUserAcceptance && workflow.state == .paused)
        #expect(workflow.tasks[0].result == "Findings for the user")
        #expect(workflow.tasks[0].completionConfirmed == true && workflow.tasks[0].reviewBlock == nil)
        // Verify the old shape reproduces the original failure, then reads the migrated form.
        #expect(throws: (any Error).self) { try JSONDecoder().decode(OldWorkflow.self, from: Self.p6b3) }
        let data = try JSONEncoder().encode(workflow)
        #expect(try JSONDecoder().decode(Workflow.self, from: data) == workflow)
        let old = try JSONDecoder().decode(OldWorkflow.self, from: data)
        #expect(old.state == .paused && old.tasks[0].state == .blocked)
        #expect(old.tasks[0].completionConfirmed == true && old.tasks[0].reviewAcceptedByUser != true)
        #expect(old.tasks[0].reviewBlock?.contains("waiting for user acceptance") == true)
        #expect(old.tasks[0].error == old.tasks[0].reviewBlock)
        #expect(old.tasks[0].result == workflow.tasks[0].result)
    }

    @Test func anOldLedgerReaderLoadsWaitingAndUnrelatedWorkflows() throws {
        let ledger = try RuntimeLedger(url: RuntimeLedgerTests().ledgerURL())
        let waiting = try JSONDecoder().decode(Workflow.self, from: Self.p6b3)
        var other = waiting; other.id = UUID(); other.tasks[0].state = .queued
        try ledger.putMany([(waiting.id.uuidString, waiting), (other.id.uuidString, other)], kind: "workflow")
        let oldRecords = try ledger.records(OldWorkflow.self, kind: "workflow")
        #expect(oldRecords.map(\.id) == [waiting.id, other.id])
        #expect(oldRecords.map { $0.tasks[0].state } == [.blocked, .queued])
        #expect(try ledger.records(Workflow.self, kind: "workflow") == [waiting, other])
    }

    @Test func markerLossOnAnOldSaveStillRequiresAcceptance() throws {
        let (store, _, _, _, _, _) = try WorkflowOperationsTests().fixture()
        let waiting = try JSONDecoder().decode(Workflow.self, from: Self.p6b3)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(waiting)) as? [String: Any])
        var tasks = try #require(object["tasks"] as? [[String: Any]])
        tasks[0].removeValue(forKey: "awaitingUserAcceptance") // Old encoders ignore and drop unknown keys.
        object["tasks"] = tasks
        let restored = try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.tasks[0].state == .blocked)
        #expect(store.canAcceptWorkflowReview(restored, task: restored.tasks[0]))
        #expect(!store.canReassignWorkflowTask(restored, task: restored.tasks[0]))
        try store.saveWorkflow(restored)
        store.confirmTeamEvidence(restored.id, taskID: "review"); store.settleWorkflows()
        #expect(store.workflows[restored.id]?.tasks[0].state == .blocked)
    }

    @Test func ordinaryTaskStatesAndOptionalFieldsStillRoundTrip() throws {
        var task = try JSONDecoder().decode(Workflow.self, from: Self.p6b3).tasks[0]
        task.resultArtifactID = UUID(); task.replyID = UUID(); task.previousThreadIDs = [UUID()]
        task.parentTaskID = "parent"; task.handoffDepth = 2; task.reportedResult = "Structured findings"
        task.reviewVerdict = .needsRevision; task.reviewBlock = "Open findings"; task.error = "Open findings"
        task.reviewAcceptedByUser = false; task.verifiedByUser = false; task.reservation = 10
        let envelope = TeamEnvelope(operationID: "TEST-delivery", taskID: task.id, conversationID: UUID(),
            recipient: .init(botID: task.botID, connection: "TEST", profile: "TEST"),
            replyToID: "parent", kind: "review", payload: "TEST findings")
        var delivery = try TeamDelivery(envelope: envelope, sessionID: "TEST-session", replyID: UUID(), at: Date(timeIntervalSince1970: 123))
        delivery.runID = "TEST-run"; delivery.submissionStarted = true; delivery.record(.completed, at: Date(timeIntervalSince1970: 124))
        task.delivery = delivery
        for state in [WorkflowTask.State.queued, .running, .completed, .blocked, .cancelled, .awaitingUserAcceptance] {
            task.state = state
            let encoded = try JSONEncoder().encode(task)
            #expect(try JSONDecoder().decode(WorkflowTask.self, from: encoded) == task)
        }
    }
}

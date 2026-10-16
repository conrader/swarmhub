import Foundation
import Testing
@testable import AgentApp

@MainActor struct TeamAppReviewTests {
    @Test func appReviewScopeBindsIdentityToolAccountArgumentsAndVersion() throws {
        let (store, _, id) = try WorkflowInteractionTests().fixture()
        store.authorizeTeamWorkflow(id)
        var workflow = try #require(store.workflows[id]); let bot = store.bots[0], reviewer = store.bots[1]
        workflow.coordination?.appReviews = [.init(tool: "FIXTURE_READ", account: "fixture-account", reviewer: store.teamIdentity(reviewer))]
        workflow.tasks[0].state = .running; workflow.state = .running
        try store.saveWorkflow(workflow)
        store.ensureWorkflowThread(workflow.tasks[0].threadID, workflow: workflow, bot: bot, role: .conversation)
        let thread = try #require(store.workflowThread(workflow.tasks[0].threadID, botID: bot.id)); thread.hermesSessionID = "fixture-session"
        let turn = store.beginTurn(in: thread, bot: bot, assistant: ChatMessage(role: .assistant, content: ""))
        defer { store.endTurn(turn.token) }
        var approval = ApprovalRequest(id: UUID(), title: "Read fixture", summary: "", draft: nil,
            command: #"{"app":"fixture","tool":"FIXTURE_READ","account":"fixture-account","arguments":{"target":"a"}}"#, botID: bot.id, sessionID: thread.hermesSessionID)
        #expect(store.teamAppReview(approval, bot: bot) == nil, "Backend-supplied app-looking JSON has no local authority")
        store.connectedApps.localApprovals[approval.id] = .chat
        let first = try #require(store.teamAppReview(approval, bot: bot))
        approval.command = #"{"app":"fixture","tool":"FIXTURE_READ","account":"fixture-account","arguments":{"target":"b"}}"#
        #expect(try #require(store.teamAppReview(approval, bot: bot)).2 != first.2)
        approval.command = #"{"app":"fixture","tool":"FIXTURE_READ","account":"different-account","arguments":{"target":"a"}}"#
        #expect(store.teamAppReview(approval, bot: bot) == nil)
        approval.command = #"{"app":"fixture","tool":"FIXTURE_WRITE","account":"fixture-account","arguments":{"target":"a"}}"#
        #expect(store.teamAppReview(approval, bot: bot) == nil)
        store.revokeTeamPolicy(id)
        approval.command = #"{"app":"fixture","tool":"FIXTURE_READ","account":"fixture-account","arguments":{"target":"a"}}"#
        #expect(store.teamAppReview(approval, bot: bot) == nil)
    }
}

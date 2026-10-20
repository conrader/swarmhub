import Foundation
import Testing
import SwarmHubCore
import SwarmHubCoordination
@testable import AgentApp

@MainActor struct AppConfigRegressionTests {
    @Test func narrowedActionsDispatchAndCompleteNormalReplies() async throws {
        let backend = ScriptedTurnBackend()
        let (store, author, peer) = TeamRecoveryTests().fixture(backend)
        store.appConfig = AppConfigWiringTests.bundled
        let group = GroupChat(name: "Team", memberIDs: [author.id, peer.id]); store.groups = [group]
        let workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: author.id, request: "Inspect fixture", state: .paused,
            tasks: [.init(id: "work", botID: peer.id, instructions: "Inspect", expectedOutput: "Findings", dependencies: []),
                    .init(id: "final", botID: author.id, instructions: "Consolidate", expectedOutput: "Answer", dependencies: ["work"])],
            budget: .init(id: UUID(), tokenLimit: 64_000))
        try store.saveWorkflow(workflow); store.authorizeTeamWorkflow(workflow.id)
        #expect(store.workflows[workflow.id]?.coordination?.policy.actions == (["assign", "requestReview"] as Set<String>))
        store.resumeWorkflow(workflow.id)
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 1 }
        #expect(store.workflows[workflow.id]?.tasks[0].delivery?.submissionStarted == true)
        await backend.emit(.token("Fixture findings"), .completed); await backend.end()
        try await backend.calls.wait { $0.filter { $0.hasPrefix("send:") }.count == 2 }
        await backend.emit(.token("Consolidated findings"), .completed); await backend.end()
        try await waitUntil { store.workflows[workflow.id]?.state == .completed }
        #expect(store.workflows[workflow.id]?.tasks.allSatisfy { $0.state == .completed } == true)
    }

    @Test(arguments: [WorkflowOperation.Action.assign, .requestReview])
    func onlyAllowedOperationsAreOfferedAndAccepted(action: WorkflowOperation.Action) throws {
        let fixture = WorkflowOperationsTests()
        let (store, original, _, _, owner, peer) = try fixture.fixture()
        var workflow = original; workflow.state = .paused
        try store.saveWorkflow(workflow)
        store.appConfig = AppConfigWiringTests.bundled
        store.authorizeTeamWorkflow(workflow.id)
        store.workflows[workflow.id]?.state = .running
        let tools = try #require(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: owner))
        let instructions = try tools.instructions("[[MARKER]]")
        #expect(instructions.contains("assign") && instructions.contains("requestReview"))
        #expect(!instructions.contains("requestHelp") && !instructions.contains("reportResult"))
        for action in [WorkflowOperation.Action.requestHelp, .reportResult] {
            let operation = action == .reportResult
                ? WorkflowOperation(operationID: "denied-report", action: action, result: "Findings")
                : WorkflowOperation(operationID: "denied-help", action: action, botID: peer.id, instructions: "Help", expectedOutput: "Findings")
            #expect(throws: (any Error).self) { try tools.perform(fixture.arguments(operation)) }
        }
        #expect(store.workflows[workflow.id]?.operations == nil)
        let handoff = WorkflowOperation(operationID: "allowed-handoff", action: action, botID: peer.id, instructions: "Inspect", expectedOutput: "Findings")
        _ = try tools.perform(fixture.arguments(handoff))
        #expect(store.workflows[workflow.id]?.operations?.last?.action == action)
        store.workflows[workflow.id]?.coordination?.policy.revokedAt = store.now()
        #expect(throws: (any Error).self) { try tools.validate() }
        store.workflows[workflow.id]?.coordination?.policy.revokedAt = nil
        store.workflows[workflow.id]?.coordination?.policy.expiresAt = store.now().addingTimeInterval(-1)
        #expect(throws: (any Error).self) { try tools.validate() }
        store.workflows[workflow.id]?.coordination?.policy.expiresAt = nil
        store.workflows[workflow.id]?.coordination?.policy.actions = ["assign"]
        store.workflows[workflow.id]?.coordinatorID = peer.id
        #expect(try store.workflowTools(for: .init(sessionID: "work-session", systemPrompt: "", messages: []), bot: owner) == nil)
        #expect(store.teamPolicyProblem(try #require(store.workflows[workflow.id]), botID: owner.id) == nil)
    }

    @Test func explicitFallbacksSurvivePersistenceAndBeatTheBundle() throws {
        let store = AppConfigWiringTests().makeStore()
        store.appConfig = AppConfigWiringTests.bundled
        #expect(store.effectiveModelDefaults.conversation?.model == "TEST-chat-1")
        #expect(store.effectiveModelDefaults.coding?.model == "TEST-coder-1")
        store.modelDefaults.set(.box, for: .conversation)
        store.modelDefaults.set(.box, for: .coding)
        #expect(!store.modelDefaults.isEmpty)
        store.save()
        let reopened = AppStore(storeURL: store.fileURL, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        reopened.appConfig = store.appConfig
        #expect(reopened.modelDefaults == store.modelDefaults)
        #expect(reopened.effectiveModelDefaults.conversation == nil && reopened.effectiveModelDefaults.coding == nil)
        #expect(ModelPolicy.resolve(role: .conversation, settings: nil, defaults: reopened.effectiveModelDefaults) == .init(choice: nil, source: .boxDefault))
        #expect(ModelPolicy.resolve(role: .coding, settings: nil, defaults: reopened.effectiveModelDefaults) == .init(choice: nil, source: .sameAsConversation))
        let local = try #require(ModelChoice(provider: "TEST-local", model: "TEST-picked"))
        reopened.modelDefaults.set(.choice(local), for: .conversation)
        #expect(!reopened.modelDefaults.conversationAgentDefault && reopened.effectiveModelDefaults.conversation == local)
        // Opting coding out of the bundle still means "same as conversation", as before bundles.
        #expect(ModelPolicy.resolve(role: .coding, settings: nil, defaults: reopened.effectiveModelDefaults).choice == local)
        reopened.modelDefaults.set(.inherit, for: .conversation)
        #expect(reopened.effectiveModelDefaults.conversation?.model == "TEST-chat-1")
    }

    @Test func oldStoredPairsAndNilKeepTodaysNoBundleMeaning() throws {
        for json in ["{}", #"{"conversation":null,"coding":null}"#,
                     #"{"conversation":{"provider":"TEST-local","model":"TEST-chat"},"coding":{"provider":"TEST-local","model":"TEST-code"}}"#] {
            let local = try JSONDecoder().decode(ModelDefaults.self, from: Data(json.utf8))
            #expect(local.filled(from: .compiled) == local)
            #expect(!local.conversationAgentDefault && !local.codingAgentDefault)
            let bundled = local.filled(from: AppConfigWiringTests.bundled)
            #expect(bundled.conversation?.model == (local.conversation?.model ?? "TEST-chat-1"))
            #expect(bundled.coding?.model == (local.coding?.model ?? "TEST-coder-1"))
        }
        var explicit = ModelDefaults()
        explicit.set(.box, for: .conversation); explicit.set(.box, for: .coding)
        #expect(explicit.filled(from: .compiled) == explicit)
    }
}

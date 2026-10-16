import AppKit
import SwiftUI
import SwarmHubCoordination

@MainActor enum HeadlessTeamShots {
    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        let lead = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "lead")
        let peer = Bot(name: "Infra", backend: .hermes, hermesProfile: "infra")
        store.bots = [lead, peer]
        let group = GroupChat(name: "Operations", memberIDs: store.bots.map(\.id)); store.groups = [group]
        let request = "Check the backup and report the result here."
        let user = ChatMessage(role: .user, content: request); group.messages = [user]
        let policy = TeamPolicy(originID: group.id, decision: request, members: store.bots.map(store.teamIdentity), ownerDeviceID: "preview")
        var task = WorkflowTask(id: "backup-check", botID: peer.id, instructions: request, expectedOutput: "Observed backup time and test result", dependencies: [], state: .blocked)
        let envelope = TeamEnvelope(operationID: "backup-check", taskID: task.id, conversationID: group.id, recipient: store.teamIdentity(peer), replyToID: nil, kind: "task", payload: request)
        task.delivery = try? TeamDelivery(envelope: envelope, sessionID: "preview", replyID: UUID(), at: .now)
        task.delivery?.record(.uncertain, at: .now); task.error = "Connection ended before completion was confirmed. Check the remote work before retrying."
        var workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: lead.id, request: request, state: .paused,
            tasks: [task, .init(id: "summary", botID: lead.id, instructions: "Summarize the result", expectedOutput: "Answer", dependencies: [task.id])],
            budget: .init(id: UUID(), tokenLimit: 64_000))
        workflow.coordination = .init(policy: policy, originMessageID: user.id); store.workflows[workflow.id] = workflow
        write("team-uncertain", await png(AnyView(GroupChatView(group: group)), store, NSSize(width: 1000, height: 1100)))
        store.projectFacts = [.init(projectID: group.id, text: "Backups should include a restore check.", source: "User decision in Operations", owner: "User", at: .now, kind: .userDecision, readers: store.bots.map(store.teamIdentity))]
        write("team-project-context", await png(AnyView(ProjectContextView(projectID: group.id, members: store.bots)), store, NSSize(width: 560, height: 700)))
    }
}

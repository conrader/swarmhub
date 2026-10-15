import AppKit
import SwiftUI

/// P38 E shots of `--render-setup` (alone with `--only p38e`): a workflow paused on a help handoff (the expanded plan
/// with where each new task came from and the handoff history), a second review that still found problems waiting for
/// "Accept review with noted limitations", and a chat whose queued message came back after a restart because an
/// earlier reply was unconfirmed. All synthetic and in memory: nothing is sent, no ledger file is written.
@MainActor enum HeadlessP38EShots {
    static let names = ["p38e-workflow-handoff", "p38e-workflow-review-accept", "p38e-chat-queue-given-back"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let lead = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let research = Bot(name: "Research", title: "Sources and facts", backend: .hermes, hermesProfile: "research")
        let cfo = Bot(name: "Cfo", title: "Budgets and invoices", backend: .hermes, hermesProfile: "cfo")
        for (index, bot) in [lead, research, cfo].enumerated() { bot.avatarName = BotAvatarName.allCases[min(index * 3, BotAvatarName.allCases.count - 1)] }
        store.bots = [lead, research, cfo]
        let group = GroupChat(name: "Q4 planning", memberIDs: [lead.id, research.id, cfo.id]); store.groups = [group]; store.selectedGroup = group
        let now = Date.now
        let ask = "Prepare a one-page Q4 budget proposal: what we spent in Q3, what the market data says, and three options."
        group.messages = [ChatMessage(role: .user, content: "Let's plan Q4 together this week.", createdAt: now.addingTimeInterval(-900))]
        let size = NSSize(width: 820, height: 1_000)
        func groupShot() -> AnyView { AnyView(GroupChatView(group: group).frame(width: size.width, height: size.height)) }

        // 1. Cfo asked Research for help while working: a helper task and a continuation wait for approval.
        var spend = WorkflowTask(id: "q3-spend", botID: cfo.id, instructions: "Total Q3 spend by category from the October invoices.", expectedOutput: "A table of Q3 spend", dependencies: [], state: .completed,
                                 result: "Q3 spend: software 41,200 · contractors 28,950 · travel 6,310 · other 3,140 (EUR).")
        spend.reportedResult = spend.result
        var helper = WorkflowTask(id: "task-supplier-rates", botID: research.id, instructions: "Find the current day rates of our two contractor agencies.", expectedOutput: "Two rates with sources", dependencies: ["q3-spend"])
        helper.parentTaskID = "q3-spend"; helper.handoffDepth = 1
        var continuation = WorkflowTask(id: "continue-q3-spend", botID: cfo.id, instructions: "Continue the original task using the helper's result. Original task: Total Q3 spend by category.",
                                        expectedOutput: "A table of Q3 spend", dependencies: ["q3-spend", "task-supplier-rates"])
        continuation.parentTaskID = "q3-spend"; continuation.handoffDepth = 0
        let synthesis = WorkflowTask(id: "synthesis", botID: lead.id, instructions: "Produce one final answer to the original request. Original request: " + ask, expectedOutput: "One consolidated answer",
                                     dependencies: ["continue-q3-spend"])
        var handoff = Workflow(id: UUID(), groupID: group.id, coordinatorID: lead.id, request: ask, createdAt: now.addingTimeInterval(-600), deadline: now.addingTimeInterval(1_300), state: .paused,
                               tasks: [spend, helper, continuation, synthesis], budget: .init(id: UUID(), tokenLimit: 64_000, spent: 5_940))
        handoff.error = "New handoff tasks need your review. Work already sent may finish; approve the plan to send the new tasks."
        handoff.operations = [.init(id: "q3-spend-help", taskID: "q3-spend", action: .requestHelp, fingerprint: "", createdTaskIDs: ["task-supplier-rates", "continue-q3-spend"],
                                    message: "Handoff saved for user review."),
                              .init(id: "q3-spend-result", taskID: "q3-spend", action: .reportResult, fingerprint: "", createdTaskIDs: [], message: "Result recorded.")]
        store.workflows = [handoff.id: handoff]
        write(names[0], await png(groupShot(), store, size))

        // 2. The second review still found problems: the synthesis waits for the user.
        var work = WorkflowTask(id: "market", botID: research.id, instructions: "Summarise current market rates for our three biggest cost lines.", expectedOutput: "Three short findings with sources", dependencies: [], state: .completed,
                                result: "Cloud rates flat, contractor day rates +4%, travel −6% year on year.")
        work.reviewRootID = "market"
        var review = WorkflowTask(id: "review-2", botID: cfo.id, instructions: "Check the claims against our invoices.", expectedOutput: "Verdict and findings", dependencies: ["market"], state: .blocked,
                                  result: "The travel figure still uses 2024 prices; the −6% is not supported by the October invoices.")
        review.reviewTargetID = "market"; review.reviewRootID = "market"; review.reviewRound = 2; review.reviewVerdict = .needsRevision; review.completionConfirmed = true; review.parentTaskID = "review-1"
        review.reviewBlock = "The review reached its revision or task limit. Read the findings, then accept the review with its noted limitations or cancel this workflow."
        review.error = review.reviewBlock
        let final = WorkflowTask(id: "synthesis", botID: lead.id, instructions: "Produce one final answer to the original request. Original request: " + ask, expectedOutput: "One consolidated answer", dependencies: ["review-2"])
        var reviewed = Workflow(id: UUID(), groupID: group.id, coordinatorID: lead.id, request: ask, createdAt: now.addingTimeInterval(-1_200), deadline: now.addingTimeInterval(600), state: .paused,
                                tasks: [work, review, final], budget: .init(id: UUID(), tokenLimit: 64_000, spent: 14_380))
        reviewed.error = review.reviewBlock
        store.workflows = [reviewed.id: reviewed]
        write(names[1], await png(groupShot(), store, size))

        // 3. After a restart: the reply the quit cut off is unconfirmed, so the queued correction came back.
        store.workflows = [:]; store.selectedGroup = nil; store.selectedBot = cfo; cfo.hermesSessionID = "agentapp_cfo"
        let question = ChatMessage(role: .user, content: "List every unpaid October invoice.", createdAt: now.addingTimeInterval(-300))
        let cut = ChatMessage(role: .assistant, content: "Checking the October folder: Northwind (2,400), Contoso", createdAt: now.addingTimeInterval(-290), turnState: .incomplete)
        let correction = ChatMessage(role: .user, content: "Only invoices above 1,000 EUR, please.", createdAt: now.addingTimeInterval(-280), metadata: [SteerKey.steer: "failed"])
        cfo.messages = [question, cut, correction]
        store.addWarning("A queued message was not sent after the restart: an earlier reply is not confirmed yet. Refresh that reply, then send the message again.", in: cfo, after: cut)
        let chat = VStack(alignment: .leading, spacing: 0) { ForEach(cfo.messages) { MessageView(message: $0) }; Spacer() }.padding(.top, 10)
        write(names[2], await png(AnyView(chat.frame(width: 820, height: 520, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 520)))
    }
}

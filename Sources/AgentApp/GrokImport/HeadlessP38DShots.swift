import AppKit
import SwiftUI

/// P38 D shots of `--render-setup` (alone with `--only p38d`): a group's workflow waiting for approval, one with a task
/// that did not finish, a completed one with its result in the group, the "Plan a workflow" sheet, delegated child
/// tasks in a chat, and routine runs caught up after the app was closed. All synthetic and in memory: workflows are set
/// on the store directly (no ledger file, no turn is sent).
@MainActor enum HeadlessP38DShots {
    static let names = ["p38d-workflow-approval", "p38d-workflow-blocked", "p38d-workflow-completed", "p38d-workflow-start",
                        "p38d-chat-child-tasks", "p38d-chat-routine-catch-up"]

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
        group.messages = [ChatMessage(role: .user, content: "Let's plan Q4 together this week.", createdAt: now.addingTimeInterval(-900)),
                          ChatMessage(role: .assistant, content: "Happy to coordinate. Use Plan a workflow and I'll split it up.", createdAt: now.addingTimeInterval(-880), authorID: lead.id, turnState: .finished)]
        func tasks() -> [WorkflowTask] {
            [.init(id: "q3-spend", botID: cfo.id, instructions: "Total Q3 spend by category from the October invoices.", expectedOutput: "A table of Q3 spend", dependencies: []),
             .init(id: "market", botID: research.id, instructions: "Summarise current market rates for our three biggest cost lines.", expectedOutput: "Three short findings with sources", dependencies: []),
             .init(id: "synthesis", botID: lead.id, instructions: "Produce one final answer to the original request. Original request: " + ask, expectedOutput: "One consolidated answer", dependencies: ["q3-spend", "market"])]
        }
        let size = NSSize(width: 820, height: 900)
        func groupShot() -> AnyView { AnyView(GroupChatView(group: group).frame(width: size.width, height: size.height)) }

        // 1. The plan came back: waiting for approval.
        var plan = Workflow(id: UUID(), groupID: group.id, coordinatorID: lead.id, request: ask, createdAt: now.addingTimeInterval(-600), state: .paused, tasks: tasks(),
                            budget: .init(id: UUID(), tokenLimit: 64_000, spent: 1_240))
        store.workflows = [plan.id: plan]
        write(names[0], await png(groupShot(), store, size))

        // 2. Running, then a task that did not finish: Refresh, Send again, reassign.
        plan.state = .paused; plan.deadline = now.addingTimeInterval(1_200)
        plan.error = "A task did not finish. Refresh it, retry it in its thread, or reassign it."
        plan.tasks[0].state = .completed; plan.tasks[0].result = "Q3 spend: software 41,200 · contractors 28,950 · travel 6,310 · other 3,140 (EUR)."
        plan.tasks[1].state = .blocked; plan.tasks[1].error = "Not sent (offline)"
        plan.budget = .init(id: plan.budget.id, tokenLimit: 64_000, spent: 6_870)
        store.workflows = [plan.id: plan]
        write(names[1], await png(groupShot(), store, size))

        // 3. Completed: every task done, one consolidated answer posted in the group.
        var done = plan
        done.state = .completed; done.error = nil; done.artifactID = UUID()
        done.tasks[1].state = .completed; done.tasks[1].error = nil; done.tasks[1].result = "Cloud rates flat, contractor day rates +4%, travel −6% year on year."
        done.tasks[2].state = .completed
        done.tasks[2].result = "Q4 proposal: hold software at Q3 level (41k), cap contractors at 30k (+4% rates absorbed by fewer days), keep travel at 6k. Option B shifts 5k to marketing; option C cuts contractors to 24k."
        done.budget = .init(id: plan.budget.id, tokenLimit: 64_000, spent: 18_420)
        store.workflows = [done.id: done]
        store.projectWorkflowResult(done)
        write(names[2], await png(groupShot(), store, size))
        group.messages.removeAll { $0.metadata["workflowID"] != nil }

        // 4. The sheet that starts one.
        store.workflows = [:]
        write(names[3], await png(AnyView(WorkflowStartSheet(group: group, request: ask, coordinatorID: lead.id).frame(width: 480, height: 330).background(AppColor.panel)), store, NSSize(width: 480, height: 330)))

        // 5. A reply that delegated two children: one finished with a transcript, one still running without a session reference.
        let finished = SubAgentTask(id: UUID(), title: "Collect October invoices", detail: "Found 14 invoices, 3 unpaid", status: .completed, sessionID: "child-invoices", runID: "run-child-1")
        let running = SubAgentTask(id: UUID(), title: "Check supplier price lists", detail: "research", status: .running)
        store.subAgentTasks[cfo.id] = [finished, running]
        let question = ChatMessage(role: .user, content: "Which invoices are still unpaid?", createdAt: now.addingTimeInterval(-120))
        let cards = [finished, running].map { task in
            ChatMessage(role: .assistant, content: task.title, presentation: .delegation,
                        metadata: ["detail": task.detail, "status": task.status.rawValue, "taskID": task.id.uuidString, "botID": cfo.id.uuidString])
        }
        let answer = ChatMessage(role: .assistant, content: "Three are unpaid: Northwind (2,400), Contoso (1,180) and Fabrikam (640).", createdAt: now.addingTimeInterval(-60), turnState: .finished)
        cfo.messages = [question] + cards + [answer]
        let chat = VStack(alignment: .leading, spacing: 0) { ForEach(cfo.messages) { MessageView(message: $0) }; Spacer() }.padding(.top, 10)
        write(names[4], await png(AnyView(chat.frame(width: 820, height: 520, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 520)))

        // 6. Two runs of a routine that finished while the app was closed, carded oldest first.
        let job = HermesJob(id: "00000000beef", name: "Morning brief", prompt: "Summarise the inbox", schedule: "0 9 * * *", scheduleKind: "cron", scheduleDisplay: "0 9 * * *",
                            enabled: true, state: "scheduled", nextRunAt: nil, lastRunAt: nil, lastStatus: "ok", lastError: nil)
        let runs = [("2026-10-13T09:00:06+02:00", "cron_00000000beef_1791874800", "Monday: 12 new emails, 2 need a reply today (accountant, landlord)."),
                    ("2026-10-14T09:00:06+02:00", "cron_00000000beef_1791961200", "Tuesday: 7 new emails, nothing urgent. The accountant replied.")]
        let routineCards = runs.map { run -> ChatMessage in
            var finishedJob = job; finishedJob.lastRunAt = run.0
            return AppStore.routineCard(job: finishedJob, result: .init(sessionID: run.1, text: run.2), lookupError: nil)
        }
        let feed = VStack(alignment: .leading, spacing: 0) { ForEach(routineCards) { MessageView(message: $0) }; Spacer() }.padding(.top, 10)
        write(names[5], await png(AnyView(feed.frame(width: 820, height: 380, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 380)))
    }
}

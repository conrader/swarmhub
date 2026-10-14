import Foundation
import Testing
@testable import AgentApp

// P32 2: the Overview's delegated tasks come from the chat's `delegate_task` steps.
@MainActor @Test func delegatedTasksComeFromDelegateTaskSteps() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let done = ChatMessage(role: .assistant, content: "ok", createdAt: t0)
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "ls"), at: t0)
    activity.apply(ToolEvent(phase: .started, name: "delegate_task", preview: "Summarise the Q3 report", callID: "a"), at: t0.addingTimeInterval(1))
    activity.apply(ToolEvent(phase: .completed, name: "delegate_task", callID: "a"), at: t0.addingTimeInterval(181))
    activity.apply(ToolEvent(phase: .started, name: "delegate_task", callID: "b"), at: t0.addingTimeInterval(200))
    activity.apply(ToolEvent(phase: .failed, name: "delegate_task", callID: "b"), at: t0.addingTimeInterval(205))
    activity.finish(at: t0.addingTimeInterval(210)); done.activity = activity
    let live = ChatMessage(role: .assistant, content: "", createdAt: t0.addingTimeInterval(300), isStreaming: true)
    var running = ToolActivity(); running.apply(ToolEvent(phase: .started, name: "delegate_task", preview: "Find hotels"), at: t0.addingTimeInterval(301))
    live.activity = running
    let bot = Bot(name: "Ada", backend: .hermes, messages: [ChatMessage(role: .user, content: "go"), done, live])
    let tasks = DelegatedTask.tasks(in: bot)
    #expect(tasks.map(\.goal) == ["Find hotels", "Delegated task", "Summarise the Q3 report"], "newest first; terminal is not a delegation")
    #expect(tasks.map(\.status) == [.running, .failed, .done])
    #expect(tasks[0].detail.hasSuffix("· still running") && tasks[0].detail.hasPrefix("Started "))
    #expect(tasks[1].detail.hasSuffix("· failed after 5 s") && tasks[2].detail.hasSuffix("· finished after 3 m 0 s"))
    live.isStreaming = false
    #expect(DelegatedTask.tasks(in: bot)[0].status == .done, "after the turn nothing runs")
    #expect(DelegatedTask.tasks(in: Bot(name: "Empty", backend: .hermes)).isEmpty)
}

@Test func overviewCopyIsHonest() {
    #expect(OverviewCopy.delegatedEmpty == "Delegated tasks from this chat appear here.")
    #expect(OverviewCopy.memoryOnBox == "This agent's memory lives on its box.")
    #expect(!OverviewCopy.memoryImported.localizedCaseInsensitiveContains("will appear"))
}

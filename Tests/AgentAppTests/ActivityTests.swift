import Foundation
import Testing
@testable import AgentApp

// P27 D9: what the bot is doing. Fixtures use the event shapes of Hermes's own `gateway/platforms/api_server.py`
// (v0.20.5): the session stream's `tool.started|completed|failed` carry `message_id, tool_name, preview, args` (+
// `session_id, run_id, seq, ts`), `tool.progress` carries `tool_name: "_thinking", delta`; the chat-completions stream's
// `hermes.tool.progress` carries `tool, emoji, label, toolCallId, status` (running|completed). Synthetic servers only.

private let secretArg = "ARGS-SECRET-VALUE-0042"

private func started(_ tool: String, _ preview: String?) -> (String, [String: Any]) {
    ("tool.started", ["message_id": "msg_1", "tool_name": tool, "preview": preview ?? NSNull(), "args": ["command": secretArg], "session_id": "s", "run_id": "run_1", "seq": 1, "ts": 1.0])
}
private func completed(_ tool: String, event: String = "tool.completed", extra: [String: Any] = [:]) -> (String, [String: Any]) {
    (event, ["message_id": "msg_1", "tool_name": tool, "preview": NSNull(), "args": NSNull(), "session_id": "s", "run_id": "run_1", "seq": 2, "ts": 2.0].merging(extra) { $1 })
}

@MainActor private func activityStore(_ events: [(String, [String: Any])], legacy: Bool = false, url: URL = temporaryStore()) -> (AppStore, Bot) {
    let stream = ChatParityServer.Reply.sse(events)
    let (_, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": !legacy]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") || path == "/v1/chat/completions" { return stream }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-activity"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes": "k"]), defaults: isolatedDefaults())
    let bot = Bot(name: "Worker", backend: .hermes, hermesProfile: "default")
    store.bots = [bot]; store.selectedBot = bot
    return (store, bot)
}

@Test @MainActor func nativeToolEventsBecomeOrderedRedactedSteps() async throws {
    let url = temporaryStore()
    let long = "grep -rn something " + String(repeating: "x", count: 200)
    let (store, bot) = activityStore([
        ("tool.progress", ["message_id": "msg_1", "tool_name": "_thinking", "delta": "pondering", "run_id": "run_1", "seq": 0, "ts": 0.5]),
        started("terminal", "ls -la /tmp"), completed("terminal"),
        started("read_file", "API_SERVER_KEY=abc123secretvalue notes.md\nsecond line"),
        started("web_search", "Bearer sk-abcdefghijklmnopqrstu and test-key here"), completed("web_search", extra: ["error": true]),
        started("terminal", long),
        ("assistant.delta", ["delta": "Done."]), ("run.completed", [:])
    ], url: url)
    #expect(store.send(text: "go")); try await waitUntil { store.isIdle }
    let reply = try #require(bot.messages.last { $0.role == .assistant })
    let activity = try #require(reply.activity)
    #expect(activity.steps.map(\.name) == ["terminal", "read_file", "web_search", "terminal"] && activity.total == 4, "_thinking is not a step")
    #expect(activity.steps[0].preview == "ls -la /tmp")
    let readPreview = try #require(activity.steps[1].preview)
    #expect(!readPreview.contains("abc123secretvalue") && readPreview.hasPrefix("API_SERVER_KEY=") && !readPreview.contains("second line"))
    let searchPreview = try #require(activity.steps[2].preview)
    #expect(!searchPreview.contains("sk-abcdefghijklmnopqrstu") && !searchPreview.contains("test-key") && activity.steps[2].failed)
    #expect(activity.steps[3].preview?.count == ToolEvent.previewLimit && activity.steps[3].preview?.hasSuffix("…") == true)
    // The turn's end closes every open step; nothing ever comes from `args`.
    #expect(activity.steps.allSatisfy { $0.finishedAt != nil } && activity.endedAt != nil)
    #expect(!activity.steps.contains { ($0.preview ?? "").contains(secretArg) })
    let saved = try String(contentsOf: url, encoding: .utf8)
    #expect(saved.contains("\"activity\"") && !saved.contains(secretArg) && !saved.contains("abc123secretvalue"))
}

@Test @MainActor func legacyToolProgressPairsByCallID() async throws {
    let (store, bot) = activityStore([
        ("hermes.tool.progress", ["tool": "terminal", "emoji": "💻", "label": "git status", "toolCallId": "call_1", "status": "running"]),
        ("hermes.tool.progress", ["tool": "terminal", "emoji": "💻", "label": "git log", "toolCallId": "call_2", "status": "running"]),
        ("hermes.tool.progress", ["tool": "terminal", "toolCallId": "call_2", "status": "completed"]),
        ("message", ["choices": [["delta": ["content": "ok"]]]])
    ], legacy: true)
    #expect(store.send(text: "go")); try await waitUntil { store.isIdle }
    let activity = try #require(bot.messages.last { $0.role == .assistant }?.activity)
    #expect(activity.steps.map(\.preview) == ["git status", "git log"] && activity.steps.map(\.callID) == ["call_1", "call_2"])
}

@Test func liveLineAndFoldedSummary() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    #expect(ActivityCopy.liveLine(nil, since: t0, now: t0.addingTimeInterval(5)) == "Thinking… · 5 s")
    activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "a.md"), at: t0.addingTimeInterval(2))
    activity.apply(ToolEvent(phase: .completed, name: "read_file"), at: t0.addingTimeInterval(3))
    #expect(ActivityCopy.liveLine(activity, since: t0, now: t0.addingTimeInterval(30)) == "Thinking… · 1 step · 30 s")
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "ls"), at: t0.addingTimeInterval(40))
    #expect(ActivityCopy.liveLine(activity, since: t0, now: t0.addingTimeInterval(72)) == "Working… · Running a command · step 2 · 1 m 12 s")
    activity.apply(ToolEvent(phase: .started, name: "mystery_tool"), at: t0.addingTimeInterval(80))
    #expect(ActivityCopy.liveLine(activity, since: t0, now: t0.addingTimeInterval(81)) == "Working… · Running mystery_tool · step 3 · 1 m 21 s")
    for index in 0..<9 { activity.apply(ToolEvent(phase: .started, name: "web_search", preview: "q\(index)"), at: t0.addingTimeInterval(100)) }
    activity.finish(at: t0.addingTimeInterval(292))
    #expect(ActivityCopy.summary(activity, since: t0) == "12 steps · 4 m 52 s")
    #expect(ActivityCopy.summary(ToolActivity(), since: t0) == nil && ActivityCopy.summary(nil, since: t0) == nil)
    #expect(ActivityCopy.label("read_file") == "Reading a file" && ActivityCopy.label("terminal") == "Running a command")
}

@Test func completionsMatchTheOldestRunningStepOfThatTool() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "one"), at: t0)
    activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "two"), at: t0)
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "three"), at: t0)
    activity.apply(ToolEvent(phase: .failed, name: "terminal"), at: t0.addingTimeInterval(1))
    #expect(activity.steps.map(\.isRunning) == [false, true, true] && activity.steps[0].failed)
    #expect(activity.current?.preview == "three")
}

@Test func activityIsBoundedAndPersistedWithTheMessage() throws {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    for index in 0..<60 { activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "step \(index)"), at: t0.addingTimeInterval(Double(index))) }
    #expect(activity.steps.count == ToolActivity.limit && activity.total == 60)
    #expect(activity.steps.first?.preview == "step 10" && activity.number(of: activity.steps[0]) == 11 && activity.number(of: activity.steps[49]) == 60)
    let message = ChatMessage(role: .assistant, content: "hi"); message.activity = activity
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded.activity == activity)
    let plain = try String(data: JSONEncoder().encode(ChatMessage(role: .assistant, content: "x")), encoding: .utf8) ?? ""
    #expect(!plain.contains("activity"), "messages without tools encode as before")
}

@Test @MainActor func sidebarShowsTheCurrentPhaseWithoutWaitingAMinute() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "ls -la"), at: t0.addingTimeInterval(5))
    #expect(ActivityCopy.sidebarLine(activity, lastText: nil, now: t0.addingTimeInterval(5)) == "Working… · Running a command · ls -la")
    #expect(ActivityCopy.sidebarLine(activity, lastText: t0.addingTimeInterval(30), now: t0.addingTimeInterval(31)) == "Typing…")
    #expect(ActivityCopy.sidebarLine(activity, lastText: t0.addingTimeInterval(30), now: t0.addingTimeInterval(80)) == "Working… · Running a command · ls -la")
    #expect(ActivityCopy.sidebarLine(ToolActivity(), lastText: nil, now: t0.addingTimeInterval(600)) == "Thinking…")
    var bare = ToolActivity(); bare.apply(ToolEvent(phase: .started, name: "terminal"), at: t0)
    #expect(ActivityCopy.sidebarLine(bare, lastText: nil, now: t0.addingTimeInterval(61)) == "Working… · Running a command")

    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Worker", backend: .hermes, hermesProfile: "default"); store.bots = [bot]
    let assistant = ChatMessage(role: .assistant, content: "", createdAt: t0, isStreaming: true); assistant.activity = activity
    bot.messages = [ChatMessage(role: .user, content: "go"), assistant]
    store.streamingBotID = bot.id; store.streamingAssistant = assistant
    let line = store.workingLine(for: bot, now: t0.addingTimeInterval(61))
    #expect(line == "Working… · Running a command · ls -la")
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: true, archiveNewest: nil, working: line) == "Working… · Running a command · ls -la")
    #expect(SidebarFragment.text(messages: bot.messages, draft: nil, isWorking: true, archiveNewest: nil, working: store.workingLine(for: bot, now: t0.addingTimeInterval(30))) == "Working… · Running a command · ls -la")
}

// P29: the row opens whenever the reply has a step, streaming or not; only a streaming reply has a running step.
@Test func activityRowUnfoldsWheneverThereIsAStep() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var activity = ToolActivity()
    #expect(!ActivityCopy.canUnfold(nil) && !ActivityCopy.canUnfold(activity), "nothing to unfold")
    #expect(ActivityCopy.isRowShown(nil, streaming: true) && ActivityCopy.isRowShown(activity, streaming: true), "Thinking… · 12 s")
    #expect(!ActivityCopy.isRowShown(nil, streaming: false) && !ActivityCopy.isRowShown(activity, streaming: false))
    activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "a.md"), at: t0)
    activity.apply(ToolEvent(phase: .completed, name: "read_file"), at: t0.addingTimeInterval(1))
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "ls"), at: t0.addingTimeInterval(2))
    #expect(ActivityCopy.canUnfold(activity) && ActivityCopy.isRowShown(activity, streaming: true) && ActivityCopy.isRowShown(activity, streaming: false))
    #expect(activity.steps.map { ActivityCopy.isRunning($0, streaming: true) } == [false, true])
    #expect(activity.steps.map { ActivityCopy.isRunning($0, streaming: false) } == [false, false], "after the turn no step runs")
    for _ in 0..<60 { activity.apply(ToolEvent(phase: .started, name: "terminal"), at: t0.addingTimeInterval(3)) }
    #expect(ActivityCopy.canUnfold(activity) && activity.steps.count == ToolActivity.limit && activity.total == 62)
    activity.finish(at: t0.addingTimeInterval(10))
    #expect(ActivityCopy.canUnfold(activity) && !activity.steps.contains { ActivityCopy.isRunning($0, streaming: false) })
}

@Test func activityRowHelpFitsBothStates() {
    #expect(ActivityCopy.toggleHelp(expanded: true, total: 3, streaming: true) == "Hide steps")
    #expect(ActivityCopy.toggleHelp(expanded: true, total: 3, streaming: false) == "Hide steps")
    #expect(ActivityCopy.toggleHelp(expanded: false, total: 1, streaming: true) == "Show the step so far")
    #expect(ActivityCopy.toggleHelp(expanded: false, total: 3, streaming: true) == "Show the steps so far")
    #expect(ActivityCopy.toggleHelp(expanded: false, total: 1, streaming: false) == "Show what this step was")
    #expect(ActivityCopy.toggleHelp(expanded: false, total: 12, streaming: false) == "Show what these steps were")
}

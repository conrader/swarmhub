import Foundation
import Testing
@testable import AgentApp

// P41 2: bot-to-bot messages visible while they happen. Parsing the live command (2026-10-15) from the full command
// line, never the 80-character preview. Synthetic only.

/// Jarvis's terminal command on the box; the script path alone is 88 characters.
let liveBotMsgCommand = "/home/hermes/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg --from grok-jarvis --to grok-infra --wait 300 -- 'Can you check the backup disk on box 2?'"

@Test(arguments: [
    (liveBotMsgCommand, "grok-jarvis", "Can you check the backup disk on box 2?"),
    ("bot-msg --to grok-infra --from grok-jarvis --wait 300 -- hi", "grok-jarvis", "hi"),
    ("../scripts/bot-msg --wait 60 --to grok-infra -- 'relative'", nil, "relative"),
    ("cd ~ && \"$HOME/.hermes/skills/swarmhub/swarmhub-messages/scripts/bot-msg\" --to grok-infra -- quoted", nil, "quoted"),
    ("sh scripts/bot-msg.sh --to grok-infra -- 'tell coder: use --to coder next time'", nil, "tell coder: use --to coder next time")
] as [(String, String?, String)])
func liveBotMsgCommandsParse(_ command: String, _ from: String?, _ text: String) throws {
    let call = try #require(BotMessageCall.parse(command: command))
    #expect(call.to == "grok-infra" && call.from == from && call.text == text)
}

@Test func theLiveCommandsPreviewIsCutBeforeTheRecipient() {
    let preview = ToolEvent.preview(liveBotMsgCommand)
    #expect(preview?.count == ToolEvent.previewLimit && preview?.contains("--to") == false, "the 80-character cut loses --to")
}

@Test func aStreamWithoutArgsStillGivesTheWholeCommand() throws {
    let backend = HermesBackend(baseURL: URL(string: "http://127.0.0.1:8642/v1")!, apiKey: "sk-synthetic-key", profile: "grok-jarvis")
    let started = backend.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "c1", "preview": liveBotMsgCommand])
    #expect(started.preview?.count == ToolEvent.previewLimit, "the shown preview stays short")
    #expect(started.command == liveBotMsgCommand)
    var activity = ToolActivity()
    activity.apply(started, at: Date(timeIntervalSince1970: 1_000))
    #expect(activity.steps[0].botMessage?.to == "grok-infra" && activity.steps[0].botMessage?.from == "grok-jarvis")
    // The legacy stream's label works the same way.
    let legacy = backend.legacyTool(["tool": "terminal", "label": liveBotMsgCommand, "toolCallId": "c2", "status": "running"])
    #expect(legacy.command == liveBotMsgCommand)
    // A preview is never parsed: a cut command with no `command` gives no call.
    var cut = ToolActivity()
    cut.apply(ToolEvent(phase: .started, name: "terminal", preview: "bot-msg --to grok-infra -- hi"), at: .now)
    #expect(cut.steps[0].botMessage == nil)
    // Other commands are not kept, and a key in the line is removed.
    #expect(backend.nativeTool("tool.started", ["tool_name": "terminal", "preview": "ls -la"]).command == nil)
    let keyed = backend.nativeTool("tool.started", ["tool_name": "terminal", "preview": "bot-msg --to grok-infra -- 'sk-synthetic-key'"])
    #expect(keyed.command?.contains("sk-synthetic-key") == false)
}

// MARK: Live state

/// Jarvis and Infra on one synthetic connection; the clock is fixed. `failing` makes Infra's backend unreachable.
@MainActor private func liveStore(url: URL = temporaryStore(), now: Date = Date(timeIntervalSince1970: 1_800_000_000), failing: Bool = false) -> (AppStore, Bot, Bot) {
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in
        if failing { throw BackendError.unavailable("synthetic box is down") }
        return MockBackend()
    }, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    store.now = { now }; store.botMessages.autoLoad = false
    if store.bots.isEmpty {
        store.bots = [Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"), Bot(name: "Infra", backend: .hermes, hermesProfile: "grok-infra")]
    }
    return (store, store.bots[0], store.bots[1])
}

private func threadRow(_ sender: String, mark: String, updated: Date) -> BotThreadRow {
    BotThreadRow(sessionID: BotThreadKey.sessionID(from: sender), sender: sender, mark: mark, updatedAt: updated, preview: nil)
}

@Test @MainActor func seenMarksSurviveARestart() throws {
    let url = temporaryStore(), now = Date(timeIntervalSince1970: 1_800_000_000), old = now.addingTimeInterval(-3 * 86_400)
    do {
        let (store, _, infra) = liveStore(url: url, now: now)
        store.applyBotThreadRows([threadRow("grok-jarvis", mark: "2", updated: old)], recipient: infra)
        #expect(infra.messages.isEmpty, "an old thread on the first list is recorded only")
        store.save()
    }
    let (store, _, infra) = liveStore(url: url, now: now)
    #expect(store.botMessages.marks[store.botMessageMarkKey(infra)] == ["swarmhub-from-grok-jarvis": "2"], "marks load with the store")
    store.applyBotThreadRows([threadRow("grok-jarvis", mark: "2", updated: old)], recipient: infra)
    #expect(infra.messages.isEmpty, "same mark after a restart: nothing new")
    store.applyBotThreadRows([threadRow("grok-jarvis", mark: "4", updated: old)], recipient: infra)
    #expect(infra.messages.map(\.content) == ["Jarvis wrote to Infra"], "a change around the restart is shown, whatever its date")
}

@Test @MainActor func theFirstListAfterTheUpdateShowsThreadsChangedInTheLastDay() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let (store, _, infra) = liveStore(now: now)
    #expect(store.botMessages.marks.isEmpty)
    store.applyBotThreadRows([threadRow("grok-jarvis", mark: "44", updated: now.addingTimeInterval(-3 * 3_600)),
                              threadRow("coder", mark: "2", updated: now.addingTimeInterval(-2 * 86_400))], recipient: infra)
    #expect(infra.messages.map(\.content) == ["Jarvis wrote to Infra"], "changed 3 h ago is new; 2 days ago is the baseline")
    #expect(store.hasBotMessageBadge(infra))
}

@Test @MainActor func theRecipientWorksWhileTheSendersStepRuns() throws {
    let (store, jarvis, infra) = liveStore()
    let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
    jarvis.messages = [ChatMessage(role: .user, content: "ask infra"), reply]
    store.beginTurn(in: jarvis, bot: jarvis, assistant: reply)
    #expect(store.incomingBotMessageLine(for: infra) == nil)
    var activity = ToolActivity(), start = store.now()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1", command: liveBotMsgCommand), at: start)
    reply.activity = activity
    #expect(store.incomingBotMessageLine(for: infra) == "Working… · message from Jarvis")
    #expect(store.incomingBotMessageLine(for: jarvis) == nil && !store.isWorking(infra), "the sender is not its own recipient")
    #expect(SidebarFragment.text(messages: infra.messages, draft: nil, isWorking: true, archiveNewest: nil,
                                 working: store.workingLine(for: infra) ?? store.incomingBotMessageLine(for: infra)) == "Working… · message from Jarvis")
    let step = activity.steps[0], key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
    #expect(store.chipState(for: step, key: key, streaming: true) == .asking)
    // The step ends with bot-msg's output: Infra is done, Jarvis's chip carries the reply.
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c1", result: #"{"output":"Disk at 62 %, backup ok.\n","exit_code":0}"#), at: start.addingTimeInterval(150))
    reply.activity = activity
    #expect(store.incomingBotMessageLine(for: infra) == nil, "cleared after the step")
    #expect(store.chipState(for: activity.steps[0], key: key, streaming: true) == .replied("Disk at 62 %, backup ok."))
    #expect(BotMessageCopy.replied("Infra") == "Infra replied" && BotMessageCopy.asking("Infra") == "Asked Infra…")
    store.stop()
}

@Test @MainActor func aChipWithoutOutputTakesTheReplyFromTheThread() {
    let (store, _, _) = liveStore()
    let start = Date(timeIntervalSince1970: 1_000), key = BotThreadKey(from: "grok-jarvis", to: "grok-infra")
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1", command: "bot-msg --to grok-infra -- hi"), at: start)
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "c1"), at: start.addingTimeInterval(5))
    let step = activity.steps[0]
    #expect(store.chipState(for: step, key: key, streaming: false) == .sent)
    store.botMessages.loaded[key] = [BotThreadLine(id: "0", author: "grok-infra", text: "older", date: start.addingTimeInterval(-60)),
                                     BotThreadLine(id: "1", author: "grok-jarvis", text: "hi", date: start),
                                     BotThreadLine(id: "2", author: "grok-infra", text: "hello back", date: start.addingTimeInterval(4))]
    #expect(store.chipState(for: step, key: key, streaming: false) == .replied("hello back"))
    var queued = step; queued.botMessage?.noWait = true
    #expect(store.chipState(for: queued, key: key, streaming: false) == .sent, "a queued message has no reply on its chip")
}

@Test @MainActor func anArrivalShowsAboveAnOpenSideThread() throws {
    let (store, _, infra) = liveStore()
    let parent = ChatMessage(role: .assistant, content: "parent")
    let thread = ChatThread(parentMessageID: parent.id, parentSessionID: nil, hermesSessionID: nil)
    infra.messages = [parent]; infra.threads = [thread]
    store.open(infra); store.openThreadID = thread.id
    store.applyBotThreadRows([], recipient: infra)
    store.applyBotThreadRows([threadRow("grok-jarvis", mark: "1", updated: store.now())], recipient: infra)
    #expect(store.arrivalsAboveThread(in: infra).map(\.content) == ["Jarvis wrote to Infra"], "shown while a side thread is open")
    #expect(store.hasBotMessageBadge(infra), "the chat is open, the conversation is not")
    store.openThread(BotThreadKey(from: "grok-jarvis", to: "grok-infra"))
    #expect(store.arrivalsAboveThread(in: infra).isEmpty && !store.hasBotMessageBadge(infra))
    store.closeThread()
    #expect(store.arrivalsAboveThread(in: infra).isEmpty, "the main chat has the line in its transcript")
}

@Test @MainActor func aFailedPollLeavesOneQuietLine() async {
    let (store, _, infra) = liveStore(failing: true)
    await store.checkBotMessages(for: infra)
    let problem = store.botMessages.errors[infra.id]
    #expect(problem?.contains("synthetic box is down") == true)
    #expect(BotMessageCopy.pollFailed(problem ?? "").hasPrefix("Couldn’t check bot messages: "))
    #expect(infra.messages.isEmpty)
}

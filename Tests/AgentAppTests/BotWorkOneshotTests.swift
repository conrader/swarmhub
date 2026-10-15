import Foundation
import Testing
@testable import AgentApp

// P42 6: Reactor asked Jarvis with `hermes -p grok-jarvis chat --oneshot` (live case 2026-10-15 20:23). The command is
// recognised like bot-msg and the recipient's oneshot session is found and shown. Synthetic only.

let liveOneshotCommand = "hermes -p grok-jarvis chat -Q --oneshot --max-turns 12 --run-budget 150 -q 'Wiadomosc od grok-reactor: czy masz dostep do kalendarza Konrada? Odpowiedz krotko.'"

@Test(arguments: [
    (liveOneshotCommand, "grok-jarvis", "Wiadomosc od grok-reactor: czy masz dostep do kalendarza Konrada? Odpowiedz krotko."),
    ("/usr/local/bin/hermes chat --profile=grok-infra --query 'disk?'", "grok-infra", "disk?"),
    ("cd /tmp && hermes --profile coder chat --oneshot -q hi", "coder", "hi")
] as [(String, String, String)])
func oneshotCommandsParse(_ command: String, _ to: String, _ text: String) throws {
    let call = try #require(BotMessageCall.call(in: command))
    #expect(call.to == to && call.text == text && call.oneshot == true && call.from == nil, "the sender is the bot whose step ran it")
}

@Test(arguments: ["hermes -p grok-jarvis status", "hermes chat -q 'no profile'", "echo 'hermes -p x chat -q y'", "hermes -p 'bad name' chat -q hi"])
func otherHermesCommandsAreNotMessages(_ command: String) {
    #expect(BotMessageCall.call(in: command) == nil)
}

@Test func theStreamKeepsTheWholeOneshotCommand() {
    let backend = HermesBackend(baseURL: URL(string: "http://127.0.0.1:8642/v1")!, apiKey: "sk-synthetic-key", profile: "grok-reactor")
    let started = backend.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "c1", "preview": liveOneshotCommand])
    #expect(started.command == liveOneshotCommand && started.preview?.count == ToolEvent.previewLimit)
    var activity = ToolActivity()
    activity.apply(started, at: Date(timeIntervalSince1970: 1_000))
    #expect(activity.steps[0].botMessage?.to == "grok-jarvis" && activity.steps[0].botMessage?.oneshot == true)
}

@Test @MainActor func theRecipientsOneshotSessionIsFoundAndShown() async throws {
    let clock = WorkClock(Date(timeIntervalSince1970: 1_800_000_000))
    let (store, jarvis, _) = workStore(clock: clock)
    let reactor = Bot(name: "Reactor", backend: .hermes, hermesProfile: "grok-reactor"); store.bots.append(reactor)
    let start = clock.now
    // Reactor's turn runs the command; Jarvis's oneshot session appears on the second list.
    let reply = ChatMessage(role: .assistant, content: "", createdAt: start, isStreaming: true)
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "c1", command: liveOneshotCommand), at: start)
    reply.activity = activity; reactor.messages = [ChatMessage(role: .user, content: "zapytaj jarvisa"), reply]
    var lists = 0
    store.botWork.sessionsOverride = { bot, source in
        #expect(bot.id == jarvis.id && source == "oneshot")
        lists += 1
        let old = BotSessionRow(id: "20261015_190000_aaaaaa", title: "Earlier", source: "oneshot", startedAt: start.addingTimeInterval(-3_600))
        return lists < 2 ? [old] : [BotSessionRow(id: "20261015_202332_77e6a5", title: "Wiadomosc od grok-reactor", source: "oneshot", startedAt: start.addingTimeInterval(1)), old]
    }
    let rows = [BackendMessage(id: 1, role: "user", content: "Wiadomosc od grok-reactor: czy masz dostep do kalendarza Konrada?", createdAt: start.addingTimeInterval(1)),
                BackendMessage(id: 2, role: "assistant", content: "Tak, mam dostep (tylko odczyt).", createdAt: start.addingTimeInterval(9), finishReason: "stop")]
    store.botWork.rowsOverride = { bot, session in
        #expect(bot.id == jarvis.id && session == "20261015_202332_77e6a5")
        return rows
    }
    store.noteStartedBotMessageSteps(before: nil, after: activity, sender: reactor)
    await finishWatches(store)
    #expect(lists == 2)
    let card = try #require(jarvis.messages.last)
    #expect(card.content == "Reactor wrote to Jarvis" && card.metadata[BotMessageKey.session] == "20261015_202332_77e6a5")
    #expect(card.metadata[BotWorkKey.origin] == "bot:grok-reactor" && card.metadata[BotWorkKey.reply] == "Tak, mam dostep (tylko odczyt).")
    // Reactor's chip opens that conversation.
    let call = try #require(reply.activity?.steps[0].botMessage)
    #expect(call.session == "20261015_202332_77e6a5")
    let key = try #require(store.threadKey(for: call, in: reply))
    #expect(key == BotThreadKey(from: "grok-reactor", to: "grok-jarvis", session: "20261015_202332_77e6a5") && key.sessionID == "20261015_202332_77e6a5")
}

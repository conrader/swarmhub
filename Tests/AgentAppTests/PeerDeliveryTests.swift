import Foundation
import Testing
@testable import AgentApp

@Test func peerDeliveryFlagsSurviveParsingAndPersistence() throws {
    let held = try #require(BotMessageCall.parse(command: "bot-msg --to infra --no-wait -- 'FYI --priority is text'"))
    #expect(held.isHeld && held.noWait && held.text == "FYI --priority is text")
    #expect(BotMessageCall.parse(command: "bot-msg --to infra --held --priority -- act")?.priority == true)
    #expect(BotMessageCall.parse(command: "bot-msg --to infra --priority --held -- later")?.isHeld == true)
    #expect(try JSONDecoder().decode(BotMessageCall.self, from: JSONEncoder().encode(held)) == held)
    let old = try JSONDecoder().decode(BotMessageCall.self, from: Data(#"{"to":"infra","text":"old","noWait":false}"#.utf8))
    #expect(!old.isHeld, "old saved calls used immediate delivery")
    #expect(BotMessageCall.parseOneshot(command: "hermes -p infra chat --oneshot -q act")?.isHeld == false)
}

@Test func peerAcknowledgementsAreSilentOnlyWhenTheyAreTheWholeAnswer() {
    for value in ["NO_REPLY", " \nno_reply\t", "[SILENT]"] {
        #expect(SilentReply.isSilent(value))
        #expect(BotMessageCall.reply(fromResult: value) == nil)
        #expect(!ChatMessage(role: .user, content: value).isSilent)
        #expect(ChatMessage(role: .assistant, content: value).isSilent)
    }
    #expect(BotMessageCall.reply(fromResult: #"{"output":" NO_REPLY\n"}"#) == nil)
    #expect(!SilentReply.isSilent("NO_REPLY but the build failed"))
    #expect(BotMessageCall.reply(fromResult: "NO_REPLY is the marker; the build failed") != nil)
}

@Test func peerThreadHistoryOmitsQuietAcknowledgements() {
    let key = BotThreadKey(from: "jarvis", to: "infra")
    let rows = [BackendMessage(id: 1, role: "user", content: "[Message from jarvis via SwarmHub]\nFYI"),
                BackendMessage(id: 2, role: "assistant", content: " NO_REPLY ", finishReason: "stop")]
    #expect(AppStore.threadLines(rows, key: key).map(\.text) == (["FYI"] as [String]))
}

@Test @MainActor func heldPeerStepsDoNotShowTheRecipientAsWorkingOrTheReceiptAsAReply() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let sender = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "jarvis")
    let recipient = Bot(name: "Infra", backend: .hermes, hermesProfile: "infra")
    store.bots = [sender, recipient]; store.botMessages.autoLoad = false
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "terminal", callID: "held", command: "bot-msg --to infra -- FYI"), at: store.now())
    let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true)
    assistant.activity = activity; sender.messages = [assistant]
    let turn = store.beginTurn(in: sender, bot: sender, assistant: assistant)
    let key = BotThreadKey(from: "jarvis", to: "infra")
    #expect(store.incomingBotMessageLine(for: recipient) == nil)
    #expect(store.chipState(for: activity.steps[0], key: key, streaming: true) == .held)
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "held", result: "held:abc"), at: store.now())
    assistant.activity = activity
    #expect(store.chipState(for: activity.steps[0], key: key, streaming: false) == .held)
    #expect(store.knownThreadLines(key).map(\.text) == (["FYI"] as [String]))
    #expect(store.allBotThreads().first?.lastLine == "FYI")
    #expect(BotMessageCopy.chip("Infra", .held) == "Held for Infra’s next turn")
    store.endTurn(turn.token)
}

@Test @MainActor func peerInstallEnablesTheHookAndStartsCompletionRecovery() throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false,
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let skill = try #require(SkillLibrary.bundled().first { $0.name == "swarmhub-messages" })
    let install = try #require(try store.skillInstallCommands([skill], profile: "infra"))
    #expect(install.commands.contains("python3 ~/.hermes/profiles/infra/skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py install infra"))
    #expect(install.commands.contains("hermes -p infra plugins enable swarmhub-peer"))
    #expect(install.commands.last == "python3 ~/.hermes/profiles/infra/skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py start")
}

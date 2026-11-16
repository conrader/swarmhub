import Foundation
import Testing
@testable import AgentApp

// Herdr bots write to each other: a bot names another bot, the app delivers the message and passes the answer back.

/// What the scripted agents were sent, and a way to hold one bot's answer back until the test lets it go.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: [String]] = [:], held: Set<String> = []
    func hear(_ bot: String, _ text: String) { lock.withLock { texts[bot, default: []].append(text) } }
    func heard(_ bot: String) -> [String] { lock.withLock { texts[bot] ?? [] } }
    func hold(_ bot: String) { lock.withLock { _ = held.insert(bot) } }
    func release(_ bot: String) { lock.withLock { _ = held.remove(bot) } }
    func isHeld(_ bot: String) -> Bool { lock.withLock { held.contains(bot) } }
}

/// A Herdr agent that answers from a script: what it is sent decides what it replies. While its bot is held it keeps
/// working, until it is released or stopped.
private struct ScriptedBot: AgentBackend {
    let kind = BackendKind.herdr
    let name: String
    let script: Script
    let reply: @Sendable (String, String) -> String
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let text = request.messages.last { $0.role == "user" }?.content ?? ""
        script.hear(name, text)
        return AsyncThrowingStream { continuation in
            let task = Task {
                while script.isHeld(name) {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { continuation.finish(throwing: CancellationError()); return }
                }
                continuation.yield(.replace(reply(name, text))); continuation.yield(.completed); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "Scripted" }
}

private func block(_ json: String) -> String { "```swarmhub\n\(json)\n```" }
private func write(to name: String, _ text: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: ["op": "message_bot", "to": name, "message": text], options: [.sortedKeys])) ?? Data()
    return block(String(decoding: data, as: UTF8.self))
}

/// "Ask Legal: question" from the person makes a bot write to Legal. A bot's message that says "forward to Tax: question"
/// makes the receiving bot write to Tax before it answers; any other message is answered in words. Answers and what
/// the app itself says are taken in words, and nobody is written to again.
private func standard(_ bot: String, _ text: String) -> String {
    func forwarding(_ body: String, lead: String, says: String) -> String? {
        guard body.hasPrefix(lead), let colon = body.firstIndex(of: ":") else { return nil }
        let name = String(body[body.index(body.startIndex, offsetBy: lead.count)..<colon])
        return says + "\n\n" + write(to: name, body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    if text.hasPrefix(HerdrBotRelay.messageLead) {
        let body = text.components(separatedBy: "\n").dropFirst().first ?? ""
        return forwarding(body, lead: "forward to ", says: "Let me check.") ?? "\(bot) says: fine."
    }
    if text.hasPrefix(HerdrBotRelay.replyLead) { return "\(bot) has the answer." }
    if text.hasPrefix("[") { return "\(bot) understood." }
    return forwarding(text, lead: "Ask ", says: "Asking.") ?? "\(bot) here."
}

/// Herdr bots on one server, each answering from `reply`; the first is the server's main bot.
@MainActor private func exchangeStore(_ names: [String] = ["Jarvis", "Boppy", "Legal", "Tax"], reply: @escaping @Sendable (String, String) -> String = standard)
    -> (store: AppStore, script: Script, bots: [String: Bot]) {
    let script = Script()
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { bot in ScriptedBot(name: bot.name, script: script, reply: reply) },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let bots = names.map { Bot(name: $0, backend: .herdr) }
    store.bots = bots
    store.setCanManageBots(bots[0], true)
    return (store, script, Dictionary(uniqueKeysWithValues: bots.map { ($0.name, $0) }))
}

@MainActor private func say(_ store: AppStore, _ bot: Bot, _ text: String) { #expect(store.send(text: text, bot: bot, conversation: bot, replyToID: nil)) }
@MainActor private func relayed(_ bot: Bot, _ kind: String) -> [ChatMessage] { bot.messages.filter { $0.role == .user && $0.metadata[HerdrBotRelay.Key.kind] == kind } }
@MainActor private func lines(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }
@MainActor private func replies(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .assistant && !$0.isStreaming }.map(\.content) }
@MainActor private func answered(_ bot: Bot, _ message: ChatMessage?) -> Bool {
    guard let message, let index = bot.messages.firstIndex(where: { $0 === message }) else { return false }
    return bot.messages[index...].contains { $0.role == .assistant && !$0.isStreaming && !$0.content.isEmpty }
}
private func id(_ bot: Bot) -> String { bot.id.uuidString.lowercased() }

/// The block, the note, the line of names and the rules, without a store.
@MainActor @Test func aMessageToABotIsReadFromAReplyAndItsRulesHold() {
    let found = HerdrBotMessage.messages(in: "On it.\n\n" + block(#"[{"op":"message_bot","to":" Legal ","message":" Is clause 4 fine? "},{"op":"message_bot","to":"legal","message":"again"},{"op":"message_bot","to":"Tax","message":""},{"op":"message_bot","name":"Ops","text":"Restart it."},{"op":"request_bot","name":"X"}]"#))
    #expect(found == [HerdrBotMessage(to: "Legal", text: "Is clause 4 fine?"), HerdrBotMessage(to: "Ops", text: "Restart it.")], "one per name, none without text")
    #expect(HerdrBotMessage.messages(in: "```swarmhub\n{\"op\":\"message_bot\",\"to\":\"Half\",\"message\":\"x\"").isEmpty, "a block still being written is no message")
    let note = HerdrBotMessage.note
    #expect(note.contains(HerdrBotMessage.marker) && HerdrBotMessage.messages(in: note).map(\.to) == ["Name of the bot"] && note.contains(HerdrBotRelay.replyLead) && note.contains(HerdrBotRelay.messageLead) && note.utf8.count < 1_000)
    #expect(!note.contains(HerdrBotAsk.marker) && !note.contains(HerdrBotRequest.marker) && !note.contains(HerdrHelperNote.marker) && !HerdrBotAsk.note(main: "J").contains(HerdrBotMessage.marker) && !AppStore.herdrCreationNote.contains(HerdrBotMessage.marker), "each note is known by its own phrase")
    #expect(AppStore.herdrCreationNote.utf8.count + HerdrHelperNote.text.utf8.count + note.utf8.count + 4 + 600 <= HerdrClient.notesBytes, "the main bot's notes and 600 bytes of names fit their room")

    // The names are one line; an agent is told it once, and again, alone, whenever it has changed.
    let two = HerdrBotMessage.roster(["A", "B"]), three = HerdrBotMessage.roster(["A", "B", "C"]), lead = HerdrBotMessage.rosterLead
    #expect(two == "Bots you can write to on this server right now: \"A\", \"B\". Use a name exactly as it is written here." && HerdrBotMessage.roster([]).hasPrefix(lead + " none."))
    #expect(HerdrBotMessage.roster(["Legal \"Eagle\"", "legal \"eagle\"", "Two\nLines"]).contains("\"Legal 'Eagle'\", \"Two Lines\"."))
    #expect(HerdrBotMessage.roster((1...60).map { "Bot \($0)" }).contains("and 20 more"))
    let once = [(marker: HerdrBotMessage.marker, note: note)]
    #expect(HerdrClient.notes(reminder: nil, once: once, tasks: ["hello"], changing: [(lead, two)]) == [note, two], "an agent that never heard of it gets both")
    #expect(HerdrClient.notes(reminder: nil, once: once, tasks: ["Standing…\n" + note + "\n\n" + two, "hi"], changing: [(lead, two)]).isEmpty, "an agent that has both is told nothing")
    #expect(HerdrClient.notes(reminder: nil, once: once, tasks: ["Standing…\n" + note + "\n\n" + two, "hi"], changing: [(lead, three)]) == [three], "a new bot: only the names are told again")
    #expect(HerdrClient.notes(reminder: nil, once: once, tasks: [note + "\n\n" + two, three + "\n\nhi", "more"], changing: [(lead, two)]) == [two], "the newest telling counts")
    #expect(HerdrClient.notes(reminder: "r", once: [], tasks: []) == ["r"], "callers that pass no changing note are as before")

    // What is passed on says whose words it is, and is itself no block.
    let passed = HerdrBotRelay.message(from: "Boppy", "Is clause 4 fine?")
    #expect(passed.hasPrefix("[Message from the bot Boppy, passed on by SwarmHub]\nIs clause 4 fine?\n") && passed.contains("goes back to Boppy by itself") && HerdrBotMessage.messages(in: passed).isEmpty)
    let reply = "Clause 4 is fine.\n\n" + write(to: "Tax", "x") + "\nBye."
    #expect(HerdrBotRelay.visible(reply) == "Clause 4 is fine.\n\nBye." && HerdrBotRelay.visible("A\n```swarmhub\n{\"op\"") == "A" && HerdrBotRelay.visible("plain") == "plain")
    let back = HerdrBotRelay.reply(from: "Legal", HerdrBotRelay.visible(reply))
    #expect(back.hasPrefix("[Answer from the bot Legal, passed on by SwarmHub]\nClause 4 is fine.") && back.contains("The person did not write it.") && HerdrBotRelay.reply(from: "Legal", " ").contains("(Legal answered without words.)"))
    #expect(!back.hasPrefix(HerdrBotRelay.answerLead) && HerdrBotRelay.reply(from: "L", String(repeating: "a", count: 9_000)).count < HerdrBotMessage.answerLimit + 200)

    // Whom a message reaches.
    typealias Candidate = HerdrBotMessage.Candidate
    let others = [Candidate(id: "b", name: "Legal"), Candidate(id: "c", name: "Tax", open: false), Candidate(id: "d", name: "Ops"), Candidate(id: "e", name: "ops"), Candidate(id: "f", name: "Café")]
    #expect(HerdrBotMessage.target(named: " legal ", among: others, chain: ["a"]) == .bot("b") && HerdrBotMessage.target(named: "Cafe", among: others, chain: ["a"]) == .bot("f"))
    #expect(HerdrBotMessage.target(named: "Nobody", among: others, chain: ["a"]) == .refused(.unknown) && HerdrBotMessage.target(named: "Ops", among: others, chain: ["a"]) == .refused(.ambiguous))
    #expect(HerdrBotMessage.target(named: "Tax", among: others, chain: ["a"]) == .refused(.closed))
    #expect(HerdrBotMessage.target(named: "Legal", among: others, chain: ["x", "b", "a"]) == .refused(.inChain), "a bot is written to once in an exchange")
    #expect(HerdrBotMessage.target(named: "Legal", among: others, chain: ["w", "x", "y"]) == .bot("b") && HerdrBotMessage.target(named: "Legal", among: others, chain: ["w", "x", "y", "z"]) == .refused(.tooLong), "four bots at most")
    let refused = HerdrBotRelay.refusal(.unknown, to: "Nobody", names: ["Legal", "Ops"])
    #expect(refused.hasPrefix("[From SwarmHub]\nNo bot named \"Nobody\"") && refused.hasSuffix(HerdrBotMessage.roster(["Legal", "Ops"])) && HerdrBotMessage.messages(in: refused).isEmpty)
    for refusal in [HerdrBotMessage.Refusal.ambiguous, .closed, .inChain, .tooLong] { #expect(HerdrBotRelay.refusal(refusal, to: "X", names: []).contains("not sent")) }
    #expect(HerdrBotRelay.ids("A,b,,C") == ["a", "b", "c"] && HerdrBotRelay.joined(["A", "b"]) == "a,b" && HerdrBotRelay.ids(nil).isEmpty)
    #expect(!HerdrBotRelay.mayAsk(replyingTo: [HerdrBotRelay.Key.kind: HerdrBotRelay.message]), "a reply to a bot's message asks for no bot by itself")
    #expect(HerdrMessagingSection.caption(bot: "Legal", server: "This Mac", takes: true).contains("can write to each other by name") && HerdrMessagingSection.caption(bot: "Legal", server: "This Mac", takes: false).hasPrefix("Off: a bot that writes to Legal is told"))
}

/// Every Herdr bot is told how to write to the others and who they are; the names follow the bots of its server.
@MainActor @Test func everyBotIsToldWhoItCanWriteToAndTheNamesStayCurrent() throws {
    let (store, _, bots) = exchangeStore()
    let jarvis = try #require(bots["Jarvis"]), boppy = try #require(bots["Boppy"]), tax = try #require(bots["Tax"])
    var backend = try store.herdrBackend(for: boppy)
    #expect(backend.messageNote == HerdrBotMessage.note && backend.roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Tax"]) && backend.notes.map(\.marker) == [HerdrBotAsk.marker, HerdrHelperNote.marker, HerdrBotMessage.marker])
    #expect(backend.launchInstructions?.hasSuffix(HerdrBotMessage.note + "\n\n" + HerdrBotMessage.roster(["Jarvis", "Legal", "Tax"])) == true && backend.rosters.map(\.lead) == [HerdrBotMessage.rosterLead])
    let main = try store.herdrBackend(for: jarvis)
    #expect(main.creationNote == AppStore.herdrCreationNote && main.messageNote == HerdrBotMessage.note && main.roster == HerdrBotMessage.roster(["Boppy", "Legal", "Tax"]), "the main bot still creates bots, and writes to bots like any other")
    #expect((main.launchInstructions?.utf8.count ?? 0) <= HerdrClient.notesBytes && main.launchInstructions?.contains(main.roster ?? "-") == true, "all its notes fit")

    let scout = Bot(name: "Scout", backend: .herdr); store.bots.append(scout)
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Tax", "Scout"]), "a new bot can be written to")
    tax.name = "Taxes"
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Taxes", "Scout"]), "a renamed bot is known by its new name")
    store.delete(scout)
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Taxes"]))
    #expect(store.herdrTakesMessages(tax), "bots take messages until the person turns it off")
    store.setHerdrTakesMessages(false, for: tax)
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal"]) && store.herdrBackend(for: tax).roster == HerdrBotMessage.roster(["Jarvis", "Boppy", "Legal"]), "a bot that takes no messages is not offered, and still writes itself")
    // A bot on another server is not on the list, and has its own.
    let box = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com")
    store.saveHerdrServer(box, token: "t")
    let far = Bot(name: "Far", backend: .herdr); store.bots.append(far); store.setHerdrServer("box1", for: far)
    backend = try store.herdrBackend(for: boppy)
    let alone = try store.herdrBackend(for: far)
    #expect(backend.roster == HerdrBotMessage.roster(["Jarvis", "Legal"]) && store.herdrPeers(of: far).isEmpty && alone.roster == HerdrBotMessage.roster([]) && alone.messageNote == HerdrBotMessage.note)
}

/// A bot names another bot: the message appears in that bot's chat, marked as passed on; the sender's chat says what
/// was sent; the answer comes back into the sender's chat as a message its agent reads; and nothing more follows.
@MainActor @Test func aBotWritesToAnotherBotAndTheAnswerComesBackIntoItsChat() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.answer).first) && store.isIdle(boppy) && store.isIdle(legal) }
    let message = try #require(relayed(legal, HerdrBotRelay.message).first)
    #expect(message.content == HerdrBotRelay.message(from: "Boppy", "Is clause 4 fine?") && store.herdrRelayCaption(message) == "Passed on by SwarmHub from Boppy")
    #expect(message.metadata[HerdrBotRelay.ExchangeKey.chain] == "\(id(boppy)),\(id(legal))" && message.metadata[HerdrBotRelay.Key.asker] == id(boppy))
    #expect(script.heard("Legal") == [message.content], "the receiving agent is sent the message")
    #expect(lines(boppy).contains("Boppy wrote to Legal: “Is clause 4 fine?”"), "the sender's chat shows what it wrote")
    #expect(HerdrBotMessage.messages(in: replies(boppy)[0]).count == 1 && HerdrBotRelay.visible(replies(boppy)[0]) == "Asking.", "the reply keeps its block, which the chat hides like every such block")
    let answer = try #require(relayed(boppy, HerdrBotRelay.answer).first)
    #expect(answer.content == HerdrBotRelay.reply(from: "Legal", "Legal says: fine.") && store.herdrRelayCaption(answer) == "Passed on by SwarmHub: the answer from Legal")
    #expect(lines(legal).contains("Legal’s answer was passed back to Boppy."))
    #expect(script.heard("Boppy") == ["Ask Legal: Is clause 4 fine?", answer.content] && replies(boppy).last == "Boppy has the answer.", "the sender's agent reads the answer")
    #expect(relayed(legal, HerdrBotRelay.message).count == 1 && relayed(boppy, HerdrBotRelay.answer).count == 1 && relayed(boppy, HerdrBotRelay.notice).isEmpty && script.heard("Legal").count == 1, "a reply to an answer sends nothing by itself")
    // A bot that was deleted since keeps its name over what it wrote.
    store.delete(legal)
    #expect(store.herdrRelayCaption(answer) == "Passed on by SwarmHub: the answer from Legal")
}

/// The receiver is in the middle of an answer: the message waits in its chat as the next message and goes when that
/// answer ends.
@MainActor @Test func aMessageToABotThatIsAnsweringWaitsItsTurn() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    script.hold("Legal")
    say(store, legal, "Read this long contract.")
    try await waitUntil { script.heard("Legal").count == 1 }
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { relayed(legal, HerdrBotRelay.message).count == 1 && store.isIdle(boppy) }
    let message = try #require(relayed(legal, HerdrBotRelay.message).first)
    #expect(message.metadata[TurnWaitCopy.key] == "waiting" && store.hasWaitingTurn(in: legal) && !store.isIdle(legal) && script.heard("Legal") == ["Read this long contract."], "it waits; the running answer is not disturbed")
    #expect(lines(boppy).contains("Boppy wrote to Legal: “Is clause 4 fine?”") && relayed(boppy, HerdrBotRelay.answer).isEmpty)
    script.release("Legal")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.answer).first) && store.isIdle(boppy) && store.isIdle(legal) }
    #expect(script.heard("Legal") == ["Read this long contract.", message.content] && message.metadata[TurnWaitCopy.key] == nil)
    #expect(replies(legal) == ["Legal here.", "Legal says: fine."] && relayed(boppy, HerdrBotRelay.answer).first?.content.contains("Legal says: fine.") == true, "the answer to the person is not passed on; the answer to the bot is")
}

/// Two bots cannot answer each other for ever. A sender that writes to the same bot again in every reply is refused,
/// since that bot is already part of the exchange, and after six tries in ten minutes it is not answered any more.
@MainActor @Test func twoBotsCannotAnswerEachOtherForEver() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Boppy", text.hasPrefix("[") { return "Once more.\n\n" + write(to: "Legal", "And again?") }
        return standard(bot, text)
    }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { lines(boppy).contains { $0.contains("was not sent: it has written to other bots 6 times in the last 10 minutes") } && store.isIdle(boppy) && store.isIdle(legal) }
    #expect(script.heard("Legal").count == 1 && relayed(legal, HerdrBotRelay.message).count == 1, "the other bot is written to once")
    let notices = relayed(boppy, HerdrBotRelay.notice)
    #expect(notices.count == 5 && notices.allSatisfy { $0.content.contains("\"Legal\" is already part of this exchange") } && store.herdrRelayCaption(notices[0]) == "From SwarmHub: a message to Legal that was not sent")
    #expect(script.heard("Boppy").count == 7 && relayed(boppy, HerdrBotRelay.answer).count == 1, "its seventh try is answered by nobody, so it ends")
    // The person writes again: a new exchange, but the ten minutes still count.
    say(store, boppy, "Ask Legal: One more?")
    try await waitUntil { store.isIdle(boppy) && lines(boppy).filter { $0.contains("was not sent: it has written to other bots") }.count == 2 }
    #expect(script.heard("Legal").count == 1)
}

/// The receiver answers by addressing the sender with a block: those words are its answer, not a new message.
@MainActor @Test func aBlockAddressedToTheBotThatAskedIsPartOfTheAnswer() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Legal", text.hasPrefix(HerdrBotRelay.messageLead) { return "Here you go.\n\n" + write(to: "Boppy", "Clause 4 is fine.") }
        return standard(bot, text)
    }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.answer).first) && store.isIdle(boppy) && store.isIdle(legal) }
    #expect(relayed(boppy, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Legal", "Here you go.\n\nClause 4 is fine.")])
    #expect(relayed(boppy, HerdrBotRelay.message).isEmpty && relayed(legal, HerdrBotRelay.notice).isEmpty && script.heard("Legal").count == 1)
}

/// A asks B, B asks C before it answers: C's answer goes to B, and B's answer then goes back to A. C cannot write to A,
/// which is already part of the exchange.
@MainActor @Test func aBotThatIsAskedMayAskOneFurtherBotBeforeItAnswers() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Tax", text.hasPrefix(HerdrBotRelay.messageLead) { return "19 percent.\n\n" + write(to: "Boppy", "Hello from Tax.") }
        return standard(bot, text)
    }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"]), tax = try #require(bots["Tax"])
    say(store, boppy, "Ask Legal: forward to Tax: What is the rate?")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.answer).first) && store.isIdle(boppy) && store.isIdle(legal) && store.isIdle(tax) }
    let toTax = try #require(relayed(tax, HerdrBotRelay.message).first)
    #expect(toTax.content == HerdrBotRelay.message(from: "Legal", "What is the rate?") && toTax.metadata[HerdrBotRelay.ExchangeKey.chain] == "\(id(boppy)),\(id(legal)),\(id(tax))" && toTax.metadata[HerdrBotRelay.ExchangeKey.waiting] == id(boppy))
    #expect(lines(boppy).contains("Legal wrote to Tax before answering Boppy.") && lines(legal).contains("Legal wrote to Tax: “What is the rate?”"))
    // Tax tried to write to Boppy: refused, and what Tax said to that refusal is its answer to Legal.
    let refusal = try #require(relayed(tax, HerdrBotRelay.notice).first)
    #expect(refusal.content.contains("\"Boppy\" is already part of this exchange") && relayed(boppy, HerdrBotRelay.message).isEmpty)
    let fromTax = try #require(relayed(legal, HerdrBotRelay.answer).first)
    #expect(fromTax.content == HerdrBotRelay.reply(from: "Tax", "Tax understood.") && fromTax.metadata[HerdrBotRelay.ExchangeKey.waiting] == id(boppy) && store.herdrRelayCaption(fromTax) == "Passed on by SwarmHub: the answer from Tax")
    // Boppy hears from Legal once: Legal's answer after it heard from Tax, not its "Let me check."
    #expect(relayed(boppy, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Legal", "Legal has the answer.")])
    #expect(script.heard("Boppy").count == 2 && script.heard("Legal").count == 2 && script.heard("Tax").count == 2 && replies(boppy).last == "Boppy has the answer.")
}

/// An exchange passes through four bots at most: the fourth bot's message to a fifth is refused, and the answers
/// still travel back to the first.
@MainActor @Test func anExchangePassesThroughFourBotsAtMost() async throws {
    let (store, script, bots) = exchangeStore(["One", "Two", "Three", "Four", "Five"])
    let one = try #require(bots["One"]), four = try #require(bots["Four"])
    say(store, one, "Ask Two: forward to Three: forward to Four: forward to Five: Anyone there?")
    try await waitUntil { answered(one, relayed(one, HerdrBotRelay.answer).first) && store.bots.allSatisfy { store.isIdle($0) } }
    #expect(script.heard("Five").isEmpty && relayed(four, HerdrBotRelay.message).first?.metadata[HerdrBotRelay.ExchangeKey.chain]?.split(separator: ",").count == 4)
    #expect(relayed(four, HerdrBotRelay.notice).first?.content.contains("has already passed through 4 bots") == true)
    #expect(relayed(one, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Two", "Two has the answer.")] && lines(one).contains("Two wrote to Three before answering One."))
    #expect(["Two", "Three", "Four"].allSatisfy { script.heard($0).count == 2 } && script.heard("One").count == 2, "every bot answered once it had its own answer")
}

/// One bot may have six messages passed on in ten minutes; the seventh is not sent and says so in its chat.
@MainActor @Test func aBotMayWriteSixTimesInTenMinutes() async throws {
    let (store, script, bots) = exchangeStore()
    var clock = Date(timeIntervalSinceReferenceDate: 2_000_000)
    store.now = { clock }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    for round in 1...HerdrBotRelay.messageLimit {
        say(store, boppy, "Ask Legal: Question \(round)?")
        try await waitUntil { relayed(boppy, HerdrBotRelay.answer).count == round && answered(boppy, relayed(boppy, HerdrBotRelay.answer).last) && store.isIdle(boppy) && store.isIdle(legal) }
    }
    say(store, boppy, "Ask Legal: One too many?")
    try await waitUntil { store.isIdle(boppy) && lines(boppy).contains("Boppy’s message to “Legal” was not sent: it has written to other bots 6 times in the last 10 minutes.") }
    #expect(script.heard("Legal").count == 6 && relayed(boppy, HerdrBotRelay.notice).isEmpty, "the seventh stays with the sender, and its agent is not sent anything for it")
    clock += HerdrBotRelay.window + 1
    say(store, boppy, "Ask Legal: And now?")
    try await waitUntil { script.heard("Legal").count == 7 && relayed(boppy, HerdrBotRelay.answer).count == 7 && store.isIdle(boppy) && store.isIdle(legal) }
}

/// A name no bot has, or two bots have, is refused back to the sender with the names it can write to.
@MainActor @Test func anUnknownOrAmbiguousNameIsRefusedWithTheNames() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"])
    say(store, boppy, "Ask Nobody: Hello?")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.notice).first) && store.isIdle(boppy) }
    let refusal = try #require(relayed(boppy, HerdrBotRelay.notice).first)
    #expect(refusal.content == HerdrBotRelay.refusal(.unknown, to: "Nobody", names: ["Jarvis", "Legal", "Tax"]) && store.herdrRelayCaption(refusal) == "From SwarmHub: a message to Nobody that was not sent")
    #expect(script.heard("Boppy").last == refusal.content && replies(boppy).last == "Boppy understood." && !lines(boppy).contains { $0.contains("wrote to") })
    #expect(["Jarvis", "Legal", "Tax"].allSatisfy { script.heard($0).isEmpty })
    // A bot cannot write to itself: its own name is not on the list.
    say(store, boppy, "Ask Boppy: Me?")
    try await waitUntil { relayed(boppy, HerdrBotRelay.notice).count == 2 && answered(boppy, relayed(boppy, HerdrBotRelay.notice).last) && store.isIdle(boppy) }
    #expect(relayed(boppy, HerdrBotRelay.notice).last?.content.hasPrefix("[From SwarmHub]\nNo bot named \"Boppy\"") == true && relayed(boppy, HerdrBotRelay.message).isEmpty)
    store.bots.append(Bot(name: "legal", backend: .herdr))
    say(store, boppy, "Ask Legal: Which of you?")
    try await waitUntil { relayed(boppy, HerdrBotRelay.notice).count == 3 && answered(boppy, relayed(boppy, HerdrBotRelay.notice).last) && store.isIdle(boppy) }
    #expect(relayed(boppy, HerdrBotRelay.notice).last?.content.contains("More than one bot on this server is named \"Legal\"") == true && script.heard("Legal").isEmpty && script.heard("legal").isEmpty)
}

/// "Other bots can message it" off: a message to that bot is refused politely; the bot itself still writes to others
/// and gets their answers.
@MainActor @Test func aBotThatTakesNoMessagesRefusesPolitelyAndStillWrites() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    store.setHerdrTakesMessages(false, for: legal)
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { answered(boppy, relayed(boppy, HerdrBotRelay.notice).first) && store.isIdle(boppy) }
    let refusal = try #require(relayed(boppy, HerdrBotRelay.notice).first)
    #expect(refusal.content.contains("\"Legal\" does not take messages from other bots, so your message was not sent.") && refusal.content.hasSuffix(HerdrBotMessage.roster(["Jarvis", "Tax"])))
    #expect(script.heard("Legal").isEmpty && relayed(legal, HerdrBotRelay.message).isEmpty)
    say(store, legal, "Ask Boppy: Do you need anything?")
    try await waitUntil { answered(legal, relayed(legal, HerdrBotRelay.answer).first) && store.isIdle(legal) && store.isIdle(boppy) }
    #expect(relayed(legal, HerdrBotRelay.answer).first?.content == HerdrBotRelay.reply(from: "Boppy", "Boppy says: fine."))
    store.setHerdrTakesMessages(true, for: legal)
    say(store, boppy, "Ask Legal: And now?")
    try await waitUntil { script.heard("Legal").contains(HerdrBotRelay.message(from: "Boppy", "And now?")) && answered(boppy, relayed(boppy, HerdrBotRelay.answer).first) && store.isIdle(boppy) && store.isIdle(legal) }
}

/// The person stops the bot that is answering another bot's message: no answer goes back, the sender's chat says so,
/// and nothing else starts.
@MainActor @Test func stoppingTheAnsweringBotEndsTheExchange() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    script.hold("Legal")
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { script.heard("Legal").count == 1 && !store.isIdle(legal) && store.isIdle(boppy) }
    store.stop(legal)
    try await waitUntil { store.isIdle(legal) && lines(boppy).contains("Legal did not finish its answer to Boppy’s message, so the exchange ended there.") }
    script.release("Legal")
    #expect(relayed(boppy, HerdrBotRelay.answer).isEmpty && script.heard("Boppy").count == 1 && store.isIdle(boppy) && !store.hasWaitingTurn(in: boppy) && !store.hasWaitingTurn(in: legal))
    // What the person then asks that bot is theirs alone: its answer goes to nobody.
    say(store, legal, "Are you there?")
    try await waitUntil { replies(legal).last == "Legal here." && store.isIdle(legal) }
    #expect(relayed(boppy, HerdrBotRelay.answer).isEmpty && script.heard("Boppy").count == 1)
}

/// Stop in a chat where another bot's message still waits its turn: the message is not sent at all, the sender's chat
/// says so, and the stopped bot's later answers go to nobody. In a longer exchange every bot that waits reads it.
@MainActor @Test func stoppingABotAlsoEndsTheExchangesThatWaitInItsChat() async throws {
    let (store, script, bots) = exchangeStore()
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"]), tax = try #require(bots["Tax"])
    script.hold("Tax")
    say(store, tax, "Do my taxes.")
    try await waitUntil { script.heard("Tax").count == 1 }
    say(store, boppy, "Ask Legal: forward to Tax: What is the rate?")
    try await waitUntil { relayed(tax, HerdrBotRelay.message).count == 1 && store.isIdle(legal) && store.isIdle(boppy) }
    let waiting = try #require(relayed(tax, HerdrBotRelay.message).first)
    #expect(waiting.metadata[TurnWaitCopy.key] == "waiting" && script.heard("Tax").count == 1)
    store.stop(tax)
    try await waitUntil { store.isIdle(tax) && lines(legal).contains("Tax was stopped before it read what Legal sent, so the exchange ended there.") }
    script.release("Tax")
    #expect(lines(boppy).contains("Tax was stopped before it read what Legal sent, so the exchange ended there."), "the bot further back reads it too")
    #expect(script.heard("Tax") == ["Do my taxes."] && !store.hasWaitingTurn(in: tax) && waiting.metadata[TurnWaitCopy.key] == nil && lines(tax).contains(TurnWaitCopy.notSent))
    say(store, tax, "Are you there?")
    try await waitUntil { replies(tax).last == "Tax here." && store.isIdle(tax) }
    #expect(relayed(legal, HerdrBotRelay.answer).isEmpty && relayed(boppy, HerdrBotRelay.answer).isEmpty && script.heard("Legal").count == 1 && script.heard("Boppy").count == 1, "the message it never read is not answered later")
}

/// Bot creation is untouched. A bot's request for a bot still goes to the main bot and comes back as an outcome, in
/// the same reply as a message to another bot; and a bot that writes to the main bot gets its words back, while the
/// bot the main bot decided on is created and can be written to at once.
@MainActor @Test func botCreationStillWorksBesideMessages() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Jarvis", text.hasPrefix(HerdrBotRelay.requestLead) { return "Makes sense.\n\n" + block(#"{"op":"create_bot","decision":"decided","name":"Scout","instructions":"You scout."}"#) }
        if bot == "Jarvis", text.hasPrefix(HerdrBotRelay.messageLead) { return "I will set one up.\n\n" + block(#"{"op":"create_bot","decision":"decided","name":"Runner","instructions":"You run."}"#) }
        if bot == "Boppy", text == "Get help" { return "On it.\n\n" + block(#"{"op":"request_bot","name":"Scout","purpose":"Scouting."}"#) + "\n\n" + write(to: "Legal", "Is clause 4 fine?") }
        return standard(bot, text)
    }
    let jarvis = try #require(bots["Jarvis"]), boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Get help")
    try await waitUntil {
        relayed(boppy, HerdrBotRelay.outcome).count == 1 && relayed(boppy, HerdrBotRelay.answer).count == 1 && answered(boppy, relayed(boppy, HerdrBotRelay.outcome).first) && answered(boppy, relayed(boppy, HerdrBotRelay.answer).first)
            && store.bots.allSatisfy { store.isIdle($0) }
    }
    let scout = try #require(store.bots.first { $0.name == "Scout" })
    #expect(scout.persona == "You scout." && store.herdrUnaskedBots(of: jarvis) == [scout] && lines(jarvis).contains("Jarvis created Scout"))
    let request = try #require(relayed(jarvis, HerdrBotRelay.request).first), outcome = try #require(relayed(boppy, HerdrBotRelay.outcome).first)
    #expect(request.content.hasPrefix("[Request from the bot Boppy, passed on by SwarmHub]") && store.herdrRelayCaption(request) == "Passed on by SwarmHub from Boppy")
    #expect(outcome.content.contains("\"Scout\" you asked for now exists") && store.herdrRelayCaption(outcome) == "Passed on by SwarmHub: the answer to this bot's request")
    #expect(relayed(legal, HerdrBotRelay.message).count == 1 && relayed(boppy, HerdrBotRelay.answer).first?.content == HerdrBotRelay.reply(from: "Legal", "Legal says: fine."))
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Tax", "Scout"]), "the new bot can be written to")

    say(store, legal, "Ask Jarvis: We need a runner.")
    try await waitUntil { answered(legal, relayed(legal, HerdrBotRelay.answer).first) && store.bots.contains { $0.name == "Runner" } && store.bots.allSatisfy { store.isIdle($0) } }
    #expect(relayed(legal, HerdrBotRelay.answer).first?.content == HerdrBotRelay.reply(from: "Jarvis", "I will set one up."), "the main bot's block is not passed back, only its words")
    #expect(store.pendingHerdrBots(for: jarvis).isEmpty && script.heard("Runner").isEmpty)
}

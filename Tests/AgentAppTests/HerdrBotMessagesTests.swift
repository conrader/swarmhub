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
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
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
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { bot in ScriptedBot(name: bot.name, script: script, reply: reply) },
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
private func pair(_ one: Bot, _ other: Bot) -> String { HerdrBotRelay.pair(id(one), id(other)) }

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
    #expect(HerdrBotMessage.target(named: " legal ", among: others) == .bot("b") && HerdrBotMessage.target(named: "Cafe", among: others) == .bot("f"))
    #expect(HerdrBotMessage.target(named: "Nobody", among: others) == .refused(.unknown) && HerdrBotMessage.target(named: "Ops", among: others) == .refused(.ambiguous))
    #expect(HerdrBotMessage.target(named: "Tax", among: others) == .refused(.closed))
    let pair = HerdrBotRelay.pair("B", "a")
    #expect(pair == "a+b" && pair == HerdrBotRelay.pair("a", "b") && HerdrBotRelay.rounds(nil).isEmpty && HerdrBotRelay.rounds("a+b:3,a+c:1,junk,x:0") == ["a+b": 3, "a+c": 1] && HerdrBotRelay.joined(rounds: ["a+c": 1, "a+b": 3]) == "a+b:3,a+c:1")
    #expect(HerdrBotMessage.target(named: "Legal", among: others, from: "a", rounds: [pair: HerdrBotRelay.roundLimit - 1]) == .bot("b")
            && HerdrBotMessage.target(named: "Legal", among: others, from: "a", rounds: [pair: HerdrBotRelay.roundLimit]) == .refused(.spent)
            && HerdrBotMessage.target(named: "Legal", among: others, from: "d", rounds: [pair: HerdrBotRelay.roundLimit]) == .bot("b"), "the same two bots write to each other eight times at most; another bot still may")
    #expect(HerdrBotRelay.roundLimit == 8 && note.contains("write to it again to follow up") && note.contains("at most 8 times about one matter"), "the bots are told that they may follow up, and where it ends")
    let refused = HerdrBotRelay.refusal(.unknown, to: "Nobody", names: ["Legal", "Ops"])
    #expect(refused.hasPrefix("[From SwarmHub]\nNo bot named \"Nobody\"") && refused.hasSuffix(HerdrBotMessage.roster(["Legal", "Ops"])) && HerdrBotMessage.messages(in: refused).isEmpty)
    for refusal in [HerdrBotMessage.Refusal.ambiguous, .closed, .spent] { #expect(HerdrBotRelay.refusal(refusal, to: "X", names: []).contains("not sent")) }
    #expect(HerdrBotRelay.ids("A,b,,C") == ["a", "b", "c"] && HerdrBotRelay.joined(["A", "b"]) == "a,b" && HerdrBotRelay.ids(nil).isEmpty)
    #expect(!HerdrBotRelay.mayAsk(replyingTo: [HerdrBotRelay.Key.kind: HerdrBotRelay.message]), "a reply to a bot's message asks for no bot by itself")
    #expect(HerdrMessagingSection.caption(bot: "Legal", server: "This Mac", takes: true).contains("can ask each other for help") && HerdrMessagingSection.caption(bot: "Legal", server: "This Mac", takes: false).hasPrefix("Off: other bots cannot write to Legal"))
}

/// Every Herdr bot is told how to write to the others and who they are; the names follow the bots of its server.
@MainActor @Test func everyBotIsToldWhoItCanWriteToAndTheNamesStayCurrent() throws {
    let (store, _, bots) = exchangeStore()
    let jarvis = try #require(bots["Jarvis"]), boppy = try #require(bots["Boppy"]), tax = try #require(bots["Tax"])
    var backend = try store.herdrBackend(for: boppy)
    #expect(backend.messageNote == HerdrBotMessage.note && backend.roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Tax"]) && backend.notes.map(\.marker) == [HerdrBackend.choiceMarker, HerdrBackend.draftMarker, HerdrBotAsk.marker, HerdrHelperNote.marker, HerdrBotMessage.marker, HerdrBackend.publishMarker])
    #expect(backend.launchInstructions?.hasSuffix(HerdrBotMessage.note + "\n\n" + HerdrBackend.publishNote + "\n\n" + HerdrBotMessage.roster(["Jarvis", "Legal", "Tax"])) == true && backend.rosters.map(\.lead) == [HerdrBotMessage.rosterLead])
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
    #expect(message.content == HerdrBotRelay.message(from: "Boppy", "Is clause 4 fine?") && store.herdrRelayCaption(message) == "Message from Boppy")
    #expect(message.metadata[HerdrBotRelay.ExchangeKey.chain] == "\(id(boppy)),\(id(legal))" && message.metadata[HerdrBotRelay.Key.asker] == id(boppy))
    #expect(script.heard("Legal") == [message.content], "the receiving agent is sent the message")
    #expect(lines(boppy).contains("Boppy wrote to Legal: “Is clause 4 fine?”"), "the sender's chat shows what it wrote")
    #expect(HerdrBotMessage.messages(in: replies(boppy)[0]).count == 1 && HerdrBotRelay.visible(replies(boppy)[0]) == "Asking.", "the reply keeps its block, which the chat hides like every such block")
    let answer = try #require(relayed(boppy, HerdrBotRelay.answer).first)
    #expect(answer.content == HerdrBotRelay.reply(from: "Legal", "Legal says: fine.") && store.herdrRelayCaption(answer) == "Answer from Legal")
    #expect(lines(legal).contains("Legal’s answer was passed back to Boppy."))
    #expect(script.heard("Boppy") == ["Ask Legal: Is clause 4 fine?", answer.content] && replies(boppy).last == "Boppy has the answer.", "the sender's agent reads the answer")
    #expect(relayed(legal, HerdrBotRelay.message).count == 1 && relayed(boppy, HerdrBotRelay.answer).count == 1 && relayed(boppy, HerdrBotRelay.notice).isEmpty && script.heard("Legal").count == 1, "a reply to an answer sends nothing by itself")
    // A bot that was deleted since keeps its name over what it wrote.
    store.delete(legal)
    #expect(store.herdrRelayCaption(answer) == "Answer from Legal")
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

/// A bot that has its answer may write to the same bot again: a follow-up, as Grok Bot's Bots hand work to each
/// other and reply later. Both messages and both answers are in both chats, and nothing is refused.
@MainActor @Test func aBotFollowsUpWithTheBotThatAnswered() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Boppy", text.hasPrefix(HerdrBotRelay.replyLead), !text.contains("second") { return "Thanks.\n\n" + write(to: "Legal", "And clause 5, second question?") }
        if bot == "Legal", text.contains("second question") { return "The second is fine too." }
        return standard(bot, text)
    }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { relayed(boppy, HerdrBotRelay.answer).count == 2 && answered(boppy, relayed(boppy, HerdrBotRelay.answer).last) && store.isIdle(boppy) && store.isIdle(legal) }
    let sent = relayed(legal, HerdrBotRelay.message)
    #expect(sent.map(\.content) == [HerdrBotRelay.message(from: "Boppy", "Is clause 4 fine?"), HerdrBotRelay.message(from: "Boppy", "And clause 5, second question?")])
    #expect(sent.map { $0.metadata[HerdrBotRelay.ExchangeKey.rounds] } == ["\(pair(boppy, legal)):1", "\(pair(boppy, legal)):2"] && sent.allSatisfy { $0.metadata[HerdrBotRelay.ExchangeKey.chain] == "\(id(boppy)),\(id(legal))" }, "the same two bots, two messages")
    #expect(relayed(boppy, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Legal", "Legal says: fine."), HerdrBotRelay.reply(from: "Legal", "The second is fine too.")])
    #expect(relayed(boppy, HerdrBotRelay.notice).isEmpty && script.heard("Legal").count == 2 && replies(boppy).last == "Boppy has the answer.")
    #expect(lines(boppy).contains("Boppy wrote to Legal: “And clause 5, second question?”") && lines(legal).filter { $0 == "Legal’s answer was passed back to Boppy." }.count == 2)
}

/// Two bots cannot answer each other for ever. A sender that follows up after every answer has six messages passed on
/// in ten minutes; the seventh is not sent, nobody answers it, and the exchange ends.
@MainActor @Test func twoBotsCannotAnswerEachOtherForEver() async throws {
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Boppy", text.hasPrefix("[") { return "Once more.\n\n" + write(to: "Legal", "And again?") }
        return standard(bot, text)
    }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { lines(boppy).contains { $0.contains("was not sent: it has written to other bots 6 times in the last 10 minutes") } && store.isIdle(boppy) && store.isIdle(legal) }
    #expect(script.heard("Legal").count == 6 && relayed(legal, HerdrBotRelay.message).count == 6, "six messages reach the other bot")
    #expect(relayed(boppy, HerdrBotRelay.notice).isEmpty && script.heard("Boppy").count == 7 && relayed(boppy, HerdrBotRelay.answer).count == 6, "its seventh try is answered by nobody, so it ends")
    // The person writes again: a new exchange, but the ten minutes still count.
    say(store, boppy, "Ask Legal: One more?")
    try await waitUntil { store.isIdle(boppy) && lines(boppy).filter { $0.contains("was not sent: it has written to other bots") }.count == 2 }
    #expect(script.heard("Legal").count == 6)
}

/// A clock the scripted agents move, so their turns are minutes apart.
private final class SlowClock: @unchecked Sendable {
    private let lock = NSLock(); private var date = Date(timeIntervalSinceReferenceDate: 3_000_000), quiet = false
    var now: Date { lock.withLock { date } }
    func pass(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    /// From now on the sender answers in words.
    var isQuiet: Bool { lock.withLock { quiet } }
    func hush() { lock.withLock { quiet = true } }
}

/// Bots that take minutes for every turn never write six times in ten minutes, so the exchange itself has an end:
/// when two bots have written to each other eight times the ninth message is refused, the sender is told once to
/// bring the matter to the person, and a sender that tries again is not told a second time. Only the person starts a
/// new exchange.
@MainActor @Test func twoBotsWriteToEachOtherEightTimesAtMost() async throws {
    let clock = SlowClock()
    let (store, script, bots) = exchangeStore { bot, text in
        if bot == "Boppy", text.hasPrefix("["), !clock.isQuiet { clock.pass(300); return "Once more.\n\n" + write(to: "Legal", "And again?") }
        return standard(bot, text)
    }
    store.now = { clock.now }
    let boppy = try #require(bots["Boppy"]), legal = try #require(bots["Legal"])
    say(store, boppy, "Ask Legal: Is clause 4 fine?")
    try await waitUntil { lines(boppy).contains("Boppy’s message to “Legal” was not sent either. Boppy was not told again, so it stops here.") && store.isIdle(boppy) && store.isIdle(legal) }
    let sent = relayed(legal, HerdrBotRelay.message)
    #expect(script.heard("Legal").count == HerdrBotRelay.roundLimit && sent.count == 8 && sent.last?.metadata[HerdrBotRelay.ExchangeKey.rounds] == "\(pair(boppy, legal)):8" && sent.last?.metadata[HerdrBotRelay.ExchangeKey.chain] == "\(id(boppy)),\(id(legal))")
    let notices = relayed(boppy, HerdrBotRelay.notice)
    #expect(notices.count == 1 && notices[0].content.contains("You and \"Legal\" have written to each other 8 times about this") && store.herdrRelayCaption(notices[0]) == "Not sent to Legal", "told once")
    #expect(lines(legal).contains("Boppy and Legal have written to each other 8 times about this, which is the limit. Boppy was told to bring the matter to you."), "the other bot's chat says so, and its agent is not woken")
    #expect(script.heard("Boppy").count == 10 && relayed(boppy, HerdrBotRelay.answer).count == 8 && !lines(boppy).contains { $0.contains("it has written to other bots") }, "the ten-minute limit never applied")
    // The person writes again: a new exchange.
    clock.hush()
    say(store, boppy, "Ask Legal: One more?")
    try await waitUntil { relayed(boppy, HerdrBotRelay.answer).count == 9 && answered(boppy, relayed(boppy, HerdrBotRelay.answer).last) && store.isIdle(boppy) && store.isIdle(legal) }
    #expect(script.heard("Legal").count == 9 && relayed(legal, HerdrBotRelay.message).last?.metadata[HerdrBotRelay.ExchangeKey.rounds] == "\(pair(boppy, legal)):1")
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

/// A asks B, B asks C before it answers: C's answer goes to B, and B's answer then goes back to A. C may write to A,
/// which is already part of the exchange, before it answers: A's answer goes to C, and the answers travel back in order.
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
    #expect(HerdrBotRelay.rounds(toTax.metadata[HerdrBotRelay.ExchangeKey.rounds]) == [pair(boppy, legal): 1, pair(legal, tax): 1] && lines(boppy).contains("Legal wrote to Tax before answering Boppy.") && lines(legal).contains("Legal wrote to Tax: “What is the rate?”"))
    // Tax wrote to Boppy, which started the exchange: Boppy answers Tax, and Tax then answers Legal.
    let toBoppy = try #require(relayed(boppy, HerdrBotRelay.message).first)
    #expect(toBoppy.content == HerdrBotRelay.message(from: "Tax", "Hello from Tax.") && toBoppy.metadata[HerdrBotRelay.ExchangeKey.chain] == toTax.metadata[HerdrBotRelay.ExchangeKey.chain]
            && toBoppy.metadata[HerdrBotRelay.ExchangeKey.waiting] == "\(id(boppy)),\(id(legal))" && HerdrBotRelay.rounds(toBoppy.metadata[HerdrBotRelay.ExchangeKey.rounds]) == [pair(boppy, legal): 1, pair(legal, tax): 1, pair(boppy, tax): 1], "no new bot joined, and each two bots wrote once")
    #expect(relayed(tax, HerdrBotRelay.notice).isEmpty && lines(legal).contains("Tax wrote to Boppy before answering Legal."))
    #expect(relayed(tax, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Boppy", "Boppy says: fine.")])
    let fromTax = try #require(relayed(legal, HerdrBotRelay.answer).first)
    #expect(fromTax.content == HerdrBotRelay.reply(from: "Tax", "Tax has the answer.") && fromTax.metadata[HerdrBotRelay.ExchangeKey.waiting] == id(boppy) && store.herdrRelayCaption(fromTax) == "Answer from Tax")
    // Boppy hears from Legal once: Legal's answer after it heard from Tax, not its "Let me check."
    #expect(relayed(boppy, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Legal", "Legal has the answer.")])
    #expect(script.heard("Boppy").count == 3 && script.heard("Legal").count == 2 && script.heard("Tax").count == 2 && replies(boppy).last == "Boppy has the answer.")
}

/// Answers travel back through everyone who asked, including the fifth and sixth recipients.
@MainActor @Test func fifthAndLaterParticipantsReceiveAndAnswer() async throws {
    let names = ["One", "Two", "Three", "Boppy", "Jarvis", "Six"]
    let (store, script, bots) = exchangeStore(names)
    let one = try #require(bots["One"])
    say(store, one, "Ask Two: forward to Three: forward to Boppy: forward to Jarvis: forward to Six: Anyone there?")
    try await waitUntil { answered(one, relayed(one, HerdrBotRelay.answer).first) && store.bots.allSatisfy { store.isIdle($0) } }
    for (index, name) in names.enumerated().dropFirst() {
        let recipient = try #require(bots[name])
        let request = try #require(relayed(recipient, HerdrBotRelay.message).first)
        #expect(HerdrBotRelay.ids(request.metadata[HerdrBotRelay.ExchangeKey.chain]) == names.prefix(index + 1).compactMap { bots[$0].map(id) })
        #expect(relayed(recipient, HerdrBotRelay.notice).isEmpty)
    }
    #expect(relayed(one, HerdrBotRelay.answer).map(\.content) == [HerdrBotRelay.reply(from: "Two", "Two has the answer.")])
    #expect(names.dropLast().allSatisfy { script.heard($0).count == 2 } && script.heard("Six").count == 1)
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
    #expect(refusal.content == HerdrBotRelay.refusal(.unknown, to: "Nobody", names: ["Jarvis", "Legal", "Tax"]) && store.herdrRelayCaption(refusal) == "Not sent to Nobody")
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
    #expect(request.content.hasPrefix("[Request from the bot Boppy, passed on by SwarmHub]") && store.herdrRelayCaption(request) == "Boppy asks for a new bot")
    #expect(outcome.content.contains("\"Scout\" you asked for now exists") && store.herdrRelayCaption(outcome) == "SwarmHub told Boppy")
    #expect(relayed(legal, HerdrBotRelay.message).count == 1 && relayed(boppy, HerdrBotRelay.answer).first?.content == HerdrBotRelay.reply(from: "Legal", "Legal says: fine."))
    #expect(try store.herdrBackend(for: boppy).roster == HerdrBotMessage.roster(["Jarvis", "Legal", "Tax", "Scout"]), "the new bot can be written to")

    say(store, legal, "Ask Jarvis: We need a runner.")
    try await waitUntil { answered(legal, relayed(legal, HerdrBotRelay.answer).first) && store.bots.contains { $0.name == "Runner" } && store.bots.allSatisfy { store.isIdle($0) } }
    #expect(relayed(legal, HerdrBotRelay.answer).first?.content == HerdrBotRelay.reply(from: "Jarvis", "I will set one up."), "the main bot's block is not passed back, only its words")
    #expect(store.pendingHerdrBots(for: jarvis).isEmpty && script.heard("Runner").isEmpty)
}

@MainActor @Test func registeredTeamRecoversHistoryWithoutDuplicatingALiveReplyOrReplayingAHandoff() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Jarvis", backend: .herdr)
    let id = bot.id.uuidString.lowercased()
    let serverID = HerdrServer.defaultID
    let http = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace": return (200, ["core":"c", "agents":[], "templates":[]])
        case "/api/bots": return (200, ["bots":[]])
        case "/api/bots/history":
            let entries: [[String: Any]] = [
                ["id":1, "bot":id, "kind":"said", "journal":50, "text":"Read live.", "at_ms":1000, "unread":true, "notify":false],
                ["id":2, "bot":id, "kind":"said", "journal":51, "text":"Reviewer confirmed the failure.", "at_ms":2000, "unread":true, "notify":false],
                ["id":3, "bot":id, "kind":"said", "code":"direct_followup", "journal":52, "text":"Background task finished.", "at_ms":1500, "unread":true, "notify":false],
                ["id":4, "bot":id, "kind":"said", "journal":53, "text":"[SILENT]", "at_ms":2200, "unread":true, "notify":false]]
            return (200, ["items":request.url?.query?.hasPrefix("after=0&") == true ? entries : [], "more":false])
        case "/api/bots/\(id)/read": return (200, ["ok":true])
        default: return (404, [:])
        }
    }
    let server = HerdrServer(id: serverID, name: "Test", kind: .address, address: "http://\(http.host)")
    store.saveHerdrServer(server, token: "fixture")
    store.herdrClientSetup = { $0.session = http.session }
    store.bots = [bot]
    store.open(bot, helper: .init(botID: bot.id, helperID: "worker/100"))
    bot.messages = [ChatMessage(role: .assistant, content: "Read live.", createdAt: Date(timeIntervalSince1970: 1), metadata:["herdrJournal":"\(serverID):50"])]
    await store.syncTeam(server)
    #expect(store.bridgeCoordinates(bot))
    #expect(bot.messages.filter { !$0.isSilent }.map(\.content) == ["Read live.", "Background task finished.", "Reviewer confirmed the failure."])
    #expect(bot.unreadCount == 2)
    store.defaults.removeObject(forKey: "herdrTeamCursor.\(serverID)")
    await store.syncTeam(server)
    #expect(bot.messages.count == 4 && bot.unreadCount == 2)
    let readPath = "/api/bots/\(id)/read"
    #expect(!MockHTTPProtocol.recorded(http.host).contains { $0.url?.path == readPath })
    store.open(bot)
    await store.syncTeam(server)
    #expect(bot.unreadCount == 0 && MockHTTPProtocol.recorded(http.host).contains { $0.url?.path == readPath })
    let registrations = MockHTTPProtocol.recorded(http.host).filter { $0.url?.path == "/api/bots" }
    #expect(registrations.count == 1)
    let data = try #require(registrations.first?.bodyData)
    let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["replace"] as? Bool != true)
}

@MainActor @Test func syncTeamImportsOtherBotsWhileOneBotStreamsAndHoldsCursorOnlyForWorkingDirectTurn() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let jarvis = Bot(name: "Jarvis", backend: .herdr)
    let legal = Bot(name: "Legal", backend: .herdr)
    let jarvisID = jarvis.id.uuidString.lowercased()
    let legalID = legal.id.uuidString.lowercased()
    let serverID = HerdrServer.defaultID
    let http = MockHTTPProtocol.serve { request in
        switch request.url?.path {
        case "/api/workspace": return (200, ["core": "c", "agents": [], "templates": []])
        case "/api/bots": return (200, ["bots": []])
        case "/api/bots/history":
            let all: [[String: Any]] = [
                ["id": 1, "bot": jarvisID, "kind": "said", "journal": 70, "text": "Jarvis answer in flight.", "at_ms": 1000, "unread": true, "notify": false],
                ["id": 2, "bot": legalID, "kind": "said", "journal": 71, "text": "Legal finished background check.", "at_ms": 1100, "unread": true, "notify": false]
            ]
            let after = request.url?.query?.hasPrefix("after=0&") == true ? 0 : 2
            return (200, ["items": all.filter { ($0["id"] as? Int ?? 0) > after }, "more": false])
        default: return (404, [:])
        }
    }
    let server = HerdrServer(id: serverID, name: "Test", kind: .address, address: "http://\(http.host)")
    store.saveHerdrServer(server, token: "fixture")
    store.herdrClientSetup = { $0.session = http.session }
    store.bots = [jarvis, legal]
    store.selectedBot = nil

    let streaming = ChatMessage(role: .assistant, content: "Writing…", isStreaming: true, turnState: .incomplete)
    let turn = store.beginTurn(in: jarvis, bot: jarvis, assistant: streaming)

    await store.syncTeam(server)
    #expect(legal.messages.map(\.content) == ["Legal finished background check."], "another bot's history is not blocked by Jarvis's active turn")
    #expect(jarvis.messages.isEmpty && store.defaults.integer(forKey: "herdrTeamCursor.\(serverID)") == 0, "cursor holds before Jarvis's unsettled reply")

    store.endTurn(turn.token)
    await store.syncTeam(server)
    #expect(jarvis.messages.map(\.content) == ["Jarvis answer in flight."])
    #expect(legal.messages.map(\.content) == ["Legal finished background check."], "re-scanning from held cursor does not duplicate Legal's row")
    #expect(store.defaults.integer(forKey: "herdrTeamCursor.\(serverID)") == 2)
}

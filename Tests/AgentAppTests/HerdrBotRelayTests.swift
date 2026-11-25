import Foundation
import Testing
@testable import AgentApp

// One main bot per Herdr server creates bots; every other bot asks it, and the app passes the request and the answer on.

/// A Herdr agent that answers from a script: what it is sent decides what it replies.
private struct ScriptedHerdrBackend: AgentBackend {
    let kind = BackendKind.herdr
    let reply: @Sendable (String) -> String
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let text = request.messages.last { $0.role == "user" }?.content ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(.replace(reply(text))); continuation.yield(.completed); continuation.finish()
        }
    }
    func cancel(sessionID: String) async throws -> StopOutcome { .noActiveRun }
    func testConnection() async throws -> String { "Scripted" }
}

private func block(_ json: String) -> String { "```swarmhub\n\(json)\n```" }

/// Boppy asks for the bot its person names, and (wrongly) asks again in every reply to a passed-on message.
/// Jarvis, the main bot, creates "Legal" itself, leaves "Payments" to the person, refuses "Servers", and only talks about "Chat".
@MainActor private func relayStore() -> (store: AppStore, jarvis: Bot, boppy: Bot) {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { bot in
        if bot.name == "Jarvis" {
            return ScriptedHerdrBackend { text in
                if text.contains("\"Legal\"") { return "Makes sense.\n\n" + block(#"{"op":"create_bot","decision":"decided","name":"Legal","instructions":"You review contracts."}"#) }
                if text.contains("\"Payments\"") { return "The person should decide.\n\n" + block(#"{"op":"create_bot","decision":"ask","name":"Payments","instructions":"You pay invoices."}"#) }
                if text.contains("\"Servers\"") { return "No.\n\n" + block(#"{"op":"decline_bot","name":"Servers","reason":"Infra already does this."}"#) }
                return "Let us talk about it first."
            }
        }
        return ScriptedHerdrBackend { text in
            if text.hasPrefix("[") { return "Understood.\n\n" + block(#"{"op":"request_bot","name":"Again","purpose":"A request that must not be passed on."}"#) }
            let name = text.components(separatedBy: " ").last ?? "Legal"
            return "I asked.\n\n" + block("{\"op\":\"request_bot\",\"name\":\"\(name)\",\"purpose\":\"Needed for \(name.lowercased()) work.\"}")
        }
    }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let jarvis = Bot(name: "Jarvis", backend: .herdr), boppy = Bot(name: "Boppy", backend: .herdr)
    store.bots = [jarvis, boppy]
    store.setCanManageBots(jarvis, true)
    return (store, jarvis, boppy)
}

@MainActor private func ask(_ store: AppStore, _ bot: Bot, for name: String) {
    #expect(store.send(text: "Get a bot called \(name)", bot: bot, conversation: bot, replyToID: nil))
}

@MainActor private func passedOn(_ bot: Bot, _ kind: String) -> [ChatMessage] { bot.messages.filter { $0.role == .user && $0.metadata[HerdrBotRelay.Key.kind] == kind } }
@MainActor private func lines(_ bot: Bot) -> [String] { bot.messages.filter { $0.role == .system }.map(\.content) }
@MainActor private func answered(_ bot: Bot, _ message: ChatMessage?) -> Bool {
    guard let message, let index = bot.messages.firstIndex(where: { $0 === message }) else { return false }
    return bot.messages[index...].contains { $0.role == .assistant && !$0.isStreaming && !$0.content.isEmpty }
}

@MainActor @Test func theBlocksOfTheRelayAreReadFromReplies() {
    let asks = HerdrBotAsk.asks(in: "I asked.\n\n" + block(#"[{"op":"request_bot","name":" Legal ","purpose":"Reviews contracts."},{"op":"request_bot","name":"legal"},{"op":"request_bot","name":""},{"op":"create_bot","name":"X"}]"#))
    #expect(asks == [HerdrBotAsk(name: "Legal", purpose: "Reviews contracts.")] && HerdrBotAsk.asks(in: "```swarmhub\n{\"op\":\"request_bot\",\"name\":\"Half\"").isEmpty)
    let decisions = HerdrBotRequest.requests(in: block(#"[{"op":"create_bot","decision":"Decided","name":"A"},{"op":"create_bot","decision":"ask","name":"B"},{"op":"create_bot","name":"C"},{"op":"create_bot","decision":"yes","name":"D"}]"#))
    #expect(decisions.map(\.decided) == [true, false, false, false], "only the word decided creates without asking")
    #expect(HerdrBotDecline.declines(in: block(#"{"op":"decline_bot","name":"Legal","reason":"Counsel does this."}"#)) == [HerdrBotDecline(name: "Legal", reason: "Counsel does this.")])
    let request = HerdrBotRelay.request(from: "Boppy", asks[0])
    #expect(request.hasPrefix("[Request from the bot Boppy, passed on by SwarmHub]") && request.contains("Purpose: Reviews contracts.") && request.contains("create_bot block for \"Legal\"") && request.contains("decline_bot"))
    #expect(HerdrBotRequest.requests(in: request).isEmpty && HerdrBotAsk.asks(in: request).isEmpty, "the passed-on request is itself no request")
    let answer = HerdrBotRelay.answer(from: "Jarvis", [.created("Legal"), .declined("Tax", reason: "Not now.")])
    #expect(answer.hasPrefix("[Answer from the main bot Jarvis, passed on by SwarmHub]") && answer.contains("\"Legal\" you asked for now exists") && answer.contains("declined your request for a bot named \"Tax\": Not now.") && answer.hasSuffix(HerdrBotRelay.noReply))
    #expect(HerdrBotRelay.decision(.dismissed("Tax"), main: "Jarvis").hasPrefix("[From SwarmHub]") && HerdrBotRelay.noMain(asks[0]).contains("no main bot"))
    #expect(HerdrBotRelay.verdicts(in: "I would rather not.", visible: "I would rather not.").words == "I would rather not.")
    #expect(HerdrBotRelay.mayAsk(replyingTo: [:]) && !HerdrBotRelay.mayAsk(replyingTo: [HerdrBotRelay.Key.kind: HerdrBotRelay.outcome]))
    #expect(HerdrBotRelay.allowed([100, 990, 995], limit: 3, now: 1_000) && !HerdrBotRelay.allowed([500, 990, 995], limit: 3, now: 1_000) && HerdrBotRelay.allowed([500, 990, 995], limit: 3, now: 1_101))
    // Each note carries its own valid example and the phrase that shows an agent has read it.
    let main = AppStore.herdrCreationNote, other = HerdrBotAsk.note(main: "Jarvis")
    #expect(main.contains(HerdrBotRequest.marker) && HerdrBotRequest.requests(in: main).first?.decided == true && main.contains(HerdrBotRelay.requestLead) && main.contains(HerdrBotDecline.op))
    #expect(AppStore.herdrCreationNoteAsking.contains("confirm every new bot") && AppStore.herdrCreationNoteAsking.contains(HerdrBotRequest.marker))
    #expect(HerdrBotAsk.asks(in: other).map(\.name) == ["Research"] && other.contains(HerdrBotAsk.marker) && other.contains("the main bot, Jarvis,") && other.utf8.count < 1_100)
    #expect(main.utf8.count + HerdrHelperNote.text.utf8.count + 2 <= HerdrClient.notesBytes, "the main bot's notes fit their own room")
}

/// There is one main bot per server: making another bot the main bot takes the role from the first, on that server only.
@MainActor @Test func eachServerHasOneMainBot() throws {
    let (store, jarvis, boppy) = relayStore()
    let box = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com")
    store.saveHerdrServer(box, token: "t")
    let far = Bot(name: "Far", backend: .herdr); store.bots.append(far); store.setHerdrServer("box1", for: far)
    #expect(store.herdrMainBot(on: store.herdrServers[0]) === jarvis && store.herdrMainBot(on: box) == nil && store.createsHerdrBots(jarvis) && !store.createsHerdrBots(boppy))
    // Only a server's main bot wears the star; a sample agent with the flag does not.
    let manager = Bot(name: "Old", backend: .mock); manager.canManageBots = true; store.bots.append(manager)
    #expect(store.herdrMainBotLabel(jarvis) == "Main bot of This Mac" && store.herdrMainBotLabel(boppy) == nil && store.herdrMainBotLabel(far) == nil && store.herdrMainBotLabel(manager) == nil)
    store.setCanManageBots(far, true)
    #expect(store.herdrMainBot(on: box) === far && store.herdrMainBot(on: store.herdrServers[0]) === jarvis, "another server keeps its own")
    #expect(store.herdrMainBotLabel(far) == "Main bot of Box" && store.herdrMainBotLabel(jarvis) == "Main bot of This Mac", "each server's main bot has its star")
    store.setCanManageBots(boppy, true)
    #expect(store.herdrMainBot(on: store.herdrServers[0]) === boppy && !jarvis.canManageBots && far.canManageBots, "the role moves; it is never held twice")
    #expect(store.herdrMainBotLabel(jarvis) == nil && store.herdrMainBotLabel(boppy) == "Main bot of This Mac")
    #expect(store.herdrMainBotLabel(far) == "Main bot of Box")
    let nowMain = try store.herdrBackend(for: boppy), noLonger = try store.herdrBackend(for: jarvis)
    #expect(nowMain.creationNote == AppStore.herdrCreationNote && nowMain.askNote == nil && noLonger.creationNote == nil && noLonger.askNote == HerdrBotAsk.note(main: "Boppy"))
    store.setHerdrAsksFirst(true, for: boppy)
    #expect(try store.herdrBackend(for: boppy).creationNote == AppStore.herdrCreationNoteAsking)
    #expect(BotEditorAdvancedSection.mainBotCaption(bot: "Boppy", isMain: true, main: "Jarvis", server: "This Mac").contains("takes this role from Jarvis"))
    #expect(BotEditorAdvancedSection.mainBotCaption(bot: "Boppy", isMain: false, main: "Jarvis", server: "This Mac").contains("Jarvis is the main bot") && BotEditorAdvancedSection.mainBotCaption(bot: "Boppy", isMain: false, main: nil, server: "This Mac").contains("has no main bot yet"))
}

@MainActor @Test func mainBotStarUsesTheSameOwnerAsTheServerRelay() {
    let (store, jarvis, boppy) = relayStore()
    // A stale duplicate flag or an archived group must never produce a second star.
    boppy.canManageBots = true
    let archive = Bot(name: "Archive", backend: .herdr)
    archive.archivedMembers = ["Old bot"]
    archive.canManageBots = true
    store.bots.insert(archive, at: 0)
    #expect(store.herdrMainBotLabel(archive) == nil)
    #expect(store.herdrMainBotLabel(jarvis) == "Main bot of This Mac")
    #expect(store.herdrMainBotLabel(boppy) == nil)
    store.setCanManageBots(boppy, true)
    #expect(store.herdrMainBotLabel(jarvis) == nil && store.herdrMainBotLabel(boppy) == "Main bot of This Mac")
    store.setCanManageBots(boppy, false)
    #expect(store.herdrMainBotLabel(boppy) == nil)
}

/// A bot that is not the main bot asks; the main bot decides itself; the bot is created at once, the asking bot is
/// told, and its reply to that answer starts nothing new.
@MainActor @Test func aRequestIsPassedOnAndABotTheMainBotDecidedIsCreatedAtOnce() async throws {
    let (store, jarvis, boppy) = relayStore()
    ask(store, boppy, for: "Legal")
    try await waitUntil { answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).first) && store.isIdle(boppy) && store.isIdle(jarvis) }
    let request = try #require(passedOn(jarvis, HerdrBotRelay.request).first)
    #expect(request.content.hasPrefix("[Request from the bot Boppy, passed on by SwarmHub]") && request.content.contains("Needed for legal work.") && store.herdrRelayCaption(request) == "Boppy asks for a new bot")
    let legal = try #require(store.bots.first { $0.name == "Legal" })
    #expect(legal.backend == .herdr && legal.persona == "You review contracts." && store.herdrServer(for: legal).id == store.herdrServer(for: jarvis).id)
    #expect(lines(jarvis).contains("Jarvis created Legal") && store.herdrUnaskedBots(of: jarvis) == [legal] && store.pendingHerdrBots(for: jarvis).isEmpty)
    #expect(lines(boppy).contains { $0.contains("asked for a bot named “Legal”") && $0.contains("passed on to Jarvis, the main bot") })
    let outcome = try #require(passedOn(boppy, HerdrBotRelay.outcome).first)
    #expect(outcome.content.hasPrefix("[Answer from the main bot Jarvis, passed on by SwarmHub]") && outcome.content.contains("\"Legal\" you asked for now exists") && store.herdrRelayCaption(outcome) != nil)
    // Boppy's reply to the answer asked for "Again": it is not passed on, so nothing loops.
    #expect(boppy.messages.last { $0.role == .assistant }?.content.contains("\"Again\"") == true)
    #expect(passedOn(jarvis, HerdrBotRelay.request).count == 1 && !store.bots.contains { $0.name == "Again" } && !lines(boppy).contains { $0.contains("Again") })
    // The person can remove what the main bot created, or keep it.
    store.keepHerdrBot(legal)
    #expect(store.herdrUnaskedBots(of: jarvis).isEmpty && store.bots.contains { $0 === legal })
    ask(store, boppy, for: "Legal")
    try await waitUntil { passedOn(boppy, HerdrBotRelay.outcome).count == 2 && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).last) && store.isIdle(boppy) }
    #expect(passedOn(boppy, HerdrBotRelay.outcome).last?.content.contains("already exists on this server") == true && store.bots.filter { $0.name == "Legal" }.count == 1, "a name that is taken creates nothing")
}

@MainActor @Test func aBotTheMainBotCreatedCanBeRemoved() async throws {
    let (store, jarvis, boppy) = relayStore()
    ask(store, boppy, for: "Legal")
    try await waitUntil { store.bots.contains { $0.name == "Legal" } && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).first) && store.isIdle(boppy) }
    let legal = try #require(store.herdrUnaskedBots(of: jarvis).first)
    store.removeHerdrBot(legal, createdBy: jarvis)
    #expect(!store.bots.contains { $0.name == "Legal" } && store.herdrUnaskedBots(of: jarvis).isEmpty && lines(jarvis).last == "You removed Legal, which Jarvis had created.")
}

/// "ask" leaves the bot to the person: the card shows who asked, the asking bot is told that it waits, and then what
/// the person decided. With "Ask me before creating bots" on, a decided bot waits too.
@MainActor @Test func aBotLeftToThePersonWaitsAndTheAskingBotHearsTheDecision() async throws {
    let (store, jarvis, boppy) = relayStore()
    ask(store, boppy, for: "Payments")
    try await waitUntil { answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).first) && store.isIdle(boppy) && store.isIdle(jarvis) }
    #expect(!store.bots.contains { $0.name == "Payments" } && passedOn(boppy, HerdrBotRelay.outcome).first?.content.contains("proposed the bot \"Payments\" to the person") == true)
    let pending = try #require(store.pendingHerdrBots(for: jarvis).first)
    #expect(pending.request.name == "Payments" && pending.askerID == boppy.id && !pending.request.decided)
    store.refuseHerdrBot(pending, manager: jarvis)
    try await waitUntil { passedOn(boppy, HerdrBotRelay.outcome).count == 2 && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).last) && store.isIdle(boppy) }
    #expect(passedOn(boppy, HerdrBotRelay.outcome).last?.content.hasPrefix("[From SwarmHub]\nThe person dismissed the proposal for a bot named \"Payments\"") == true && store.pendingHerdrBots(for: jarvis).isEmpty)

    store.setHerdrAsksFirst(true, for: jarvis)
    ask(store, boppy, for: "Legal")
    try await waitUntil { passedOn(boppy, HerdrBotRelay.outcome).count == 3 && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).last) && store.isIdle(boppy) && store.isIdle(jarvis) }
    #expect(!store.bots.contains { $0.name == "Legal" } && passedOn(boppy, HerdrBotRelay.outcome).last?.content.contains("proposed the bot \"Legal\"") == true, "the person confirms every bot: nothing is created yet")
    let waiting = try #require(store.pendingHerdrBots(for: jarvis).first { $0.request.name == "Legal" })
    #expect(waiting.request.decided && waiting.askerID == boppy.id)
    // Jarvis answers something else meanwhile: a request made for another bot stays on offer, because that bot waits.
    #expect(store.send(text: "What do you think of a bot named \"Chat\"?", bot: jarvis, conversation: jarvis, replyToID: nil))
    try await waitUntil { store.isIdle(jarvis) && jarvis.messages.last { $0.role == .assistant }?.content == "Let us talk about it first." }
    #expect(store.pendingHerdrBots(for: jarvis).map(\.request.name) == ["Legal"])
    let created = await store.acceptHerdrBot(waiting, manager: jarvis)
    try await waitUntil { passedOn(boppy, HerdrBotRelay.outcome).count == 4 && store.isIdle(boppy) }
    #expect(created?.name == "Legal" && store.herdrUnaskedBots(of: jarvis).isEmpty && passedOn(boppy, HerdrBotRelay.outcome).last?.content.contains("\"Legal\" you asked for now exists") == true)
}

@MainActor @Test func aRefusalGoesBackWithItsReasonAndWordsAloneGoBackAsWords() async throws {
    let (store, jarvis, boppy) = relayStore()
    ask(store, boppy, for: "Servers")
    try await waitUntil { answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).first) && store.isIdle(boppy) && store.isIdle(jarvis) }
    #expect(passedOn(boppy, HerdrBotRelay.outcome).first?.content.contains("Jarvis declined your request for a bot named \"Servers\": Infra already does this.") == true)
    #expect(store.bots.count == 2 && store.pendingHerdrBots(for: jarvis).isEmpty)
    ask(store, boppy, for: "Chat")
    try await waitUntil { passedOn(boppy, HerdrBotRelay.outcome).count == 2 && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).last) && store.isIdle(boppy) }
    #expect(passedOn(boppy, HerdrBotRelay.outcome).last?.content.contains("Jarvis created no bot and answered: Let us talk about it first.") == true)
}

/// With no main bot on the server the asking bot is told so and its person reads what to do. A bot may have three
/// requests passed on in ten minutes; the fourth is not, and says so in its chat.
@MainActor @Test func noMainBotAndTooManyRequestsAreSaidPlainly() async throws {
    let (store, jarvis, boppy) = relayStore()
    var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    store.now = { clock }
    store.setCanManageBots(jarvis, false)
    ask(store, boppy, for: "Legal")
    try await waitUntil { answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).first) && store.isIdle(boppy) }
    #expect(lines(boppy).contains { $0.contains("This Mac has no main bot to decide") && $0.contains("Main bot") })
    #expect(passedOn(boppy, HerdrBotRelay.outcome).first?.content.contains("This server has no main bot") == true && passedOn(jarvis, HerdrBotRelay.request).isEmpty && store.bots.count == 2)

    store.setCanManageBots(jarvis, true); clock += 700
    for (index, name) in ["Servers", "Servers", "Servers"].enumerated() {
        ask(store, boppy, for: name)
        try await waitUntil { passedOn(jarvis, HerdrBotRelay.request).count == index + 1 && passedOn(boppy, HerdrBotRelay.outcome).count == index + 2 && answered(boppy, passedOn(boppy, HerdrBotRelay.outcome).last) && store.isIdle(boppy) && store.isIdle(jarvis) }
    }
    ask(store, boppy, for: "Servers")
    try await waitUntil { store.isIdle(boppy) && lines(boppy).contains { $0.contains("was not passed on: it has asked 3 times in the last 10 minutes") } }
    #expect(passedOn(jarvis, HerdrBotRelay.request).count == 3, "the fourth request stays with the asking bot")
    clock += 601
    ask(store, boppy, for: "Servers")
    try await waitUntil { passedOn(jarvis, HerdrBotRelay.request).count == 4 }
}

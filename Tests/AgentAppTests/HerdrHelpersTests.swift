import Foundation
import Testing
@testable import AgentApp

// Helper agents of a Herdr bot: what the bridge lists, what the bot's agent is told, which bots are read and when,
// and looking into one.

@MainActor private func helperStore() -> AppStore {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    return store
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(json.utf8))
}

private let listingJSON = """
{"core":"c0","parent":{"address":"t2x","created_ms":1794843679838},"limit":3,"helpers":[
 {"address":"t31","created_ms":1794843760636,"name":"two","terminal":"two-t2x","template":"one","model":"some-model","difficulty":"easy","task":"Reply with exactly:\\ntwo ok","started_ms":1794843760415,"state":"live","status":{"state":"done"},"reason":null,"answered":true,"reply":{"id":182,"text":"follow-up ok","at_ms":1794843937842,"truncated":false}},
 {"address":"t32","created_ms":1794843765312,"name":"three","state":"live","status":{"state":"working"},"answered":false,"reply":null},
 {"address":"t33","created_ms":1,"name":"four","state":"finished","status":null,"reason":"killed","answered":true},
 {"address":"t34","created_ms":2,"name":"five","state":"gone","some_later_field":7}]}
"""

@Test func herdrHelpersDecodeAsTheBridgeListsThem() throws {
    let list = try decoded(HerdrClient.Helpers.self, listingJSON)
    #expect(list.core == "c0" && list.limit == 3 && list.parent == HerdrClient.AgentRef(address: "t2x", createdMs: 1794843679838))
    #expect(list.helpers.map(\.name) == ["two", "three", "four", "five"] && list.helpers[0].id == "t31/1794843760636")
    #expect(list.helpers[0].runLine == "easy · some-model" && list.helpers[0].reply?.text == "follow-up ok" && list.helpers[1].runLine.isEmpty)
    #expect(list.helpers.map(\.statusLine) == ["Answered", "Working", "Ended after answering", "No longer on the server"])
    #expect(list.helpers.map(\.isLive) == [true, true, false, false] && list.helpers.map(\.isWorking) == [false, true, false, false])
    #expect(HerdrHelperRow.fragment(list.helpers[0]) == "Answered · Reply with exactly: two ok" && HerdrHelperRow.fragment(list.helpers[1]) == "Working")
    #expect(HerdrHelpersSection.count(list) == "2 of 3 running")
    #expect(HerdrHelpersSection.count(HerdrClient.Helpers(core: "c", parent: list.parent, limit: nil, helpers: [list.helpers[1]])) == "1 running")
    let waiting = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live", status: .init(state: "blocked"))
    let failed = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live", status: .init(state: "error"))
    let starting = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live"), quiet = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "finished")
    #expect([waiting, failed, starting, quiet].map(\.statusLine) == ["Waiting at a prompt", "Reported an error", "Starting", "Ended without an answer"])
}

/// A helper's terminal is named by the agent that started it; it is never taken for a bot's own agent.
@Test func aHelperIsNotABotsAgent() async throws {
    let workspace = try decoded(HerdrClient.Workspace.self, """
    {"core":"c0","version":"1","templates":[],"agents":[
     {"address":"t2x","created_ms":10,"name":"jarvis-abc123","state":"live","template":"one","status":{"state":"working"}},
     {"address":"t31","created_ms":11,"name":"abc123-t2x","state":"live","template":"one","status":null,"parent":{"address":"t2x","created_ms":10}},
     {"address":"t40","created_ms":12,"name":"other-ffffff","state":"live","template":"one","status":null}]}
    """)
    let client = HerdrClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t")
    #expect(client.liveAgent(named: "jarvis-abc123", in: workspace)?.address == "t2x" && client.liveAgent(named: "renamed-abc123", in: workspace)?.address == "t2x")
    #expect(client.liveAgent(named: "x-t2x", in: workspace) == nil)
    #expect(workspace.agents[1].parent == workspace.agents[0].ref && workspace.agents[0].parent == nil)
    let none = try await client.helpers(of: workspace.agents[2], in: workspace)
    #expect(none == nil, "an agent with no helper in the workspace costs no request")
}

@Test func aHelpersTerminalReadsAsPlainLines() {
    #expect(HerdrClient.screenText("\r\n\u{1B}[1mbold\u{1B}[0m line   \r\n\u{1B}]0;title\u{07}next\u{08}\n\n") == "bold line\nnext")
    #expect(HerdrClient.screenText(String(repeating: "0123456789\n", count: 10_000)).utf8.count <= HerdrClient.screenBytes)
    let log = HerdrClient.HelperLog(replies: [.init(id: 1, kind: "reply", text: "saved")], draft: "so far")
    #expect(log.latestReply(answered: false) == "so far" && log.latestReply(answered: true) == "saved" && HerdrClient.HelperLog().latestReply(answered: true) == nil)
}

/// The note says how to start a helper and how to choose its difficulty, and names no model: the server picks it.
@Test func theHelperNoteNamesTheCommandAndNoModel() {
    let note = HerdrHelperNote.text
    #expect(note.contains("swarmhub-herdr helper start --difficulty easy|medium|hard") && note.contains("helper wait NAME") && note.utf8.count < 1_500)
    #expect(note.contains("easy for small mechanical edits, medium for normal features and fixes, hard for design-heavy or risky work"))
    #expect(note.contains("The server picks the helper's model from the difficulty; you cannot choose it"))
    let once = (marker: HerdrHelperNote.marker, note: note)
    #expect(HerdrClient.notes(reminder: nil, once: once, tasks: ["hello"]) == [note], "a running agent that never read it is told")
    #expect(HerdrClient.notes(reminder: "r", once: once, tasks: ["Standing instructions…\n" + note, "hello"]) == ["r"], "one that read it is not told again")
    #expect(HerdrClient.notes(reminder: nil, once: nil, tasks: []).isEmpty)
}

@MainActor @Test func aBotIsToldAboutHelpersOnlyWhenItsSwitchIsOn() throws {
    let store = helperStore()
    let jarvis = Bot(name: "Jarvis", persona: String(repeating: "x", count: 9_000), backend: .herdr), plain = Bot(name: "Plain", backend: .herdr), old = Bot(name: "Old", backend: .hermes)
    store.bots = [jarvis, plain, old]
    let untold = try store.herdrBackend(for: plain)
    #expect(!store.startsHerdrHelpers(jarvis) && !store.startsHerdrHelpers(plain) && untold.helperNote == nil, "off until the person says so")
    #expect(store.startsHerdrHelpers(plain, managing: true), "the editor's unsaved switch moves the default")
    store.setCanManageBots(jarvis, true)
    #expect(store.startsHerdrHelpers(jarvis) && !store.startsHerdrHelpers(plain), "a bot that can create bots may start helpers by default")
    let told = try store.herdrBackend(for: jarvis)
    #expect(told.helperNote == HerdrHelperNote.text && told.creationNote == AppStore.herdrCreationNote)
    let launch = try #require(told.launchInstructions)
    #expect(launch.hasSuffix(AppStore.herdrCreationNote + "\n\n" + HerdrHelperNote.text) && launch.hasPrefix("xxx") && launch.utf8.count <= HerdrClient.instructionsBytes, "both notes fit after long instructions")
    store.setStartsHerdrHelpers(false, for: jarvis); store.setStartsHerdrHelpers(true, for: plain)
    let off = try store.herdrBackend(for: jarvis), on = try store.herdrBackend(for: plain)
    #expect(!store.startsHerdrHelpers(jarvis) && off.helperNote == nil && off.creationNote != nil, "its own choice wins over the default")
    #expect(store.startsHerdrHelpers(plain) && on.launchInstructions == HerdrHelperNote.text, "a bot with the default instructions still gets the note")
    store.setStartsHerdrHelpers(true, for: old)
    #expect(!store.startsHerdrHelpers(old), "only a Herdr bot has helpers")
}

/// Helpers are read for the open chat, for a bot that is answering and for a bot that shows some; no other bot is.
@MainActor @Test func helpersAreReadOnlyWhereItIsUseful() throws {
    let store = helperStore()
    let open = Bot(name: "Open", backend: .herdr), busy = Bot(name: "Busy", backend: .herdr), idle = Bot(name: "Idle", backend: .herdr), old = Bot(name: "Old", backend: .hermes)
    store.bots = [open, busy, idle, old]
    #expect(store.herdrHelperWatch().bots.isEmpty, "nothing open, nothing working: nothing is read")
    store.selectedBot = open
    var watch = store.herdrHelperWatch()
    #expect(watch.bots.map(\.name) == ["Open"] && !watch.often, "the open chat of an idle bot is read now and then")
    let list = try decoded(HerdrClient.Helpers.self, listingJSON)
    store.herdrHelpers[busy.id] = list
    watch = store.herdrHelperWatch()
    #expect(watch.bots.map(\.name) == ["Open", "Busy"] && watch.often, "a bot that shows helpers is read often, wherever the person is")
    store.selectedBot = old; store.herdrHelpers = [:]
    #expect(store.herdrHelperWatch().bots.isEmpty, "a bot of another backend has none")
    store.selectedBot = open; store.showingReports = true
    #expect(store.herdrHelperWatch().bots.isEmpty, "the chat is not on screen behind the reports")
}

@MainActor @Test func aHelperOpensInPlaceOfItsBotsChat() async throws {
    let store = helperStore()
    let jarvis = Bot(name: "Jarvis", backend: .herdr), other = Bot(name: "Other", backend: .herdr)
    store.bots = [jarvis, other]
    let list = try decoded(HerdrClient.Helpers.self, listingJSON)
    store.herdrHelpers[jarvis.id] = list
    store.open(other)
    store.open(list.helpers[1], of: jarvis)
    #expect(store.selectedBot === jarvis && store.openHerdrHelper == HerdrHelperSelection(botID: jarvis.id, helperID: "t32/1794843765312"))
    #expect(store.isOpen(list.helpers[1], of: jarvis) && !store.isOpen(list.helpers[0], of: jarvis) && !store.isOpen(list.helpers[1], of: other))
    store.open(jarvis)
    #expect(store.openHerdrHelper == nil && store.selectedBot === jarvis, "opening the bot shows its chat again")
    // A bot that was deleted takes its helpers off the screen at the next read; a server with no token shows none.
    store.bots = [other]; store.herdrHelpers[other.id] = list
    store.saveHerdrServer(HerdrServer(id: HerdrServer.defaultID, name: "Lab", kind: .address, address: "http://127.0.0.1:1"), token: nil)
    store.setHerdrToken("", for: store.herdrServers[0])
    await store.refreshHerdrHelpers(for: [other])
    #expect(store.herdrHelpers.isEmpty)
}

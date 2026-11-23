import Foundation
import Testing
@testable import AgentApp

// Helper agents of a Herdr bot: what the bridge lists, what the bot's agent is told, which bots are read and when,
// and looking into one.

@MainActor private func helperStore() -> AppStore {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    return store
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: Data(json.utf8))
}

private let listingJSON = """
{"core":"c0","parent":{"address":"t2x","created_ms":1794843679838},"limit":3,"stop_after_seconds":60,"helpers":[
 {"address":"t31","created_ms":1794843760636,"name":"two","terminal":"two-t2x","template":"one","model":"some-model","difficulty":"easy","task":"Reply with exactly:\\ntwo ok","started_ms":1794843760415,"state":"live","status":{"state":"done"},"reason":null,"answered":true,"reply":{"id":182,"text":"follow-up ok","at_ms":1794843937842,"truncated":false}},
 {"address":"t32","created_ms":1794843765312,"name":"three","state":"live","status":{"state":"working"},"answered":false,"reply":null},
 {"address":"t33","created_ms":1,"name":"four","state":"finished","status":null,"reason":"killed","answered":true},
 {"address":"t34","created_ms":2,"name":"five","state":"gone","some_later_field":7}]}
"""

@Test func herdrHelpersDecodeAsTheBridgeListsThem() throws {
    let list = try decoded(HerdrClient.Helpers.self, listingJSON)
    #expect(list.core == "c0" && list.limit == 3 && list.stopAfterSeconds == 60 && list.parent == HerdrClient.AgentRef(address: "t2x", createdMs: 1794843679838))
    #expect(list.helpers.map(\.name) == ["two", "three", "four", "five"] && list.helpers[0].id == "t31/1794843760636")
    #expect(list.helpers[0].runLine == "some-model" && list.helpers[0].difficultyLine == "Easy task" && list.helpers[0].reply?.text == "follow-up ok" && list.helpers[1].runLine.isEmpty)
    #expect(list.helpers.map(\.statusLine) == ["Answered", "Working", "Finished", "Gone"])
    #expect(list.helpers.map(\.isLive) == [true, true, false, false] && list.helpers.map(\.isWorking) == [false, true, false, false])
    #expect(HerdrHelperRow.fragment(list.helpers[0]) == "Answered · Reply with exactly: two ok" && HerdrHelperRow.fragment(list.helpers[1]) == "Working")
    #expect(HerdrHelpersSection.count(list) == "2 of 3 running")
    #expect(HerdrHelpersSection.count(HerdrClient.Helpers(core: "c", parent: list.parent, helpers: [list.helpers[1]])) == "1 running")
    let waiting = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live", status: .init(state: "blocked"))
    let failed = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live", status: .init(state: "error"))
    let starting = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "live"), quiet = HerdrClient.Helper(address: "a", createdMs: 1, name: "n", state: "finished")
    #expect([waiting, failed, starting, quiet].map(\.statusLine) == ["Waiting for an answer in its terminal", "Reported an error", "Starting", "Stopped without an answer"])
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
    #expect(note.contains("The server picks the helper's model from the difficulty; you cannot choose it") && note.contains("stops a helper a short while after it has answered"))
    let once = (marker: HerdrHelperNote.marker, note: note)
    #expect(HerdrClient.notes(reminder: nil, once: [once], tasks: ["hello"]) == [note], "a running agent that never read it is told")
    #expect(HerdrClient.notes(reminder: "r", once: [once], tasks: ["Standing instructions…\n" + note, "hello"]) == ["r"], "one that read it is not told again")
    #expect(HerdrClient.notes(reminder: nil, once: [], tasks: []).isEmpty && HerdrClient.notes(reminder: note, once: [once, once], tasks: []) == [note], "and never twice in one message")
}

/// Helpers are for every Herdr bot: the switch is on until its person turns it off, and the notes never shorten
/// the bot's own instructions.
@MainActor @Test func everyHerdrBotIsToldAboutHelpersUnlessItsSwitchIsOff() throws {
    let store = helperStore()
    let jarvis = Bot(name: "Jarvis", persona: String(repeating: "x", count: 9_000), backend: .herdr), plain = Bot(name: "Plain", backend: .herdr), old = Bot(name: "Old", backend: .mock)
    store.bots = [jarvis, plain, old]
    #expect(store.startsHerdrHelpers(jarvis) && store.startsHerdrHelpers(plain) && !store.startsHerdrHelpers(old), "on for every Herdr bot, and only for those")
    let told = try store.herdrBackend(for: plain)
    #expect(told.helperNote == HerdrHelperNote.text && told.launchInstructions == HerdrBotAsk.note(main: nil) + "\n\n" + HerdrHelperNote.text + "\n\n" + HerdrBotMessage.note + "\n\n" + HerdrBackend.publishNote + "\n\n" + HerdrBotMessage.roster(["Jarvis"]), "a bot with the default instructions gets the notes alone")
    store.setCanManageBots(jarvis, true)
    let main = try store.herdrBackend(for: jarvis)
    #expect(main.helperNote == HerdrHelperNote.text && main.creationNote == AppStore.herdrCreationNote && main.askNote == nil)
    let launch = try #require(main.launchInstructions)
    #expect(launch.hasSuffix(AppStore.herdrCreationNote + "\n\n" + HerdrHelperNote.text + "\n\n" + HerdrBotMessage.note + "\n\n" + HerdrAboutYou.how + "\n\n" + HerdrModelRequest.brief + "\n\n" + HerdrBackend.publishNote + "\n\n" + HerdrBotMessage.roster(["Plain"])) && launch.hasPrefix(String(repeating: "x", count: 6_990)), "the notes come after the bot's own instructions and do not shorten them")
    let budget = HerdrClient.firstMessageBudget(instructions: launch, hasFiles: false)
    let text = String(repeating: "m", count: budget)
    let first = HerdrClient.firstTask(text, instructions: launch)
    #expect(first.utf8.count <= HerdrClient.taskBytes && first.contains(HerdrHelperNote.text) && first.hasSuffix(text))
    #expect(throws: BackendError.self) { try HerdrClient.validateMessage(text + "m", limit: budget) }
    store.setStartsHerdrHelpers(false, for: jarvis)
    let off = try store.herdrBackend(for: jarvis)
    #expect(!store.startsHerdrHelpers(jarvis) && off.helperNote == nil && off.creationNote != nil && store.startsHerdrHelpers(plain), "its own switch turns it off for that bot only")
    #expect(off.notes.map(\.marker) == [HerdrBotRequest.marker, HerdrBotMessage.marker, HerdrAboutYou.marker, HerdrModelRequest.marker, HerdrBackend.publishMarker] && told.notes.map(\.marker) == [HerdrBotAsk.marker, HerdrHelperNote.marker, HerdrBotMessage.marker, HerdrBackend.publishMarker])
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

/// The helper settings are the server's: the form offers only what the server listed and sends its own field names back.
@Test func helperSettingsAreEditedWithTheServersOwnChoices() throws {
    let settings = try decoded(HerdrHelperSettings.self, """
    {"policy":{"max_running":3,"stop_after_seconds":90,"difficulties":{"easy":{"template":"one","model":"model-a"},"hard":{"template":"two","model":"model-c"}}},
     "problem":null,"bounds":{"max_running":{"min":0,"max":16},"stop_after_seconds":{"min":5,"max":86400,"default":60}}}
    """)
    var draft = HerdrHelperPolicyDraft(settings)
    #expect(draft.stopUnansweredSeconds == nil && draft.unansweredDelays().isEmpty && draft.policy.body["stop_unanswered_after_seconds"] == nil, "an older server has no such setting and is not sent one")
    #expect(draft.maxRunning == 3 && draft.stopAfterSeconds == 90 && draft.runningRange == 0...16 && draft.stopAfterRange == 5...86_400)
    #expect(draft.tiers == ["easy": .init(template: "one", model: "model-a"), "hard": .init(template: "two", model: "model-c")] && draft.policy == settings.policy && draft.problem == nil)
    #expect(draft.delays() == [15, 30, 60, 90, 120, 300, 900, 3_600], "round delays, and the saved one whatever it is")
    #expect([5, 60, 90, 120, 3_600, 7_200, 86_400].map(HerdrHelperPolicyDraft.delayLabel) == ["5 seconds", "1 minute", "90 seconds", "2 minutes", "1 hour", "2 hours", "24 hours"])
    let offered = [HerdrClient.Template.Model(id: "model-b", label: nil), HerdrClient.Template.Model(id: "model-c", label: nil)]
    draft.setTemplate("two", for: "medium", offered: offered)
    #expect(draft.tiers["medium"] == .init(template: "two", model: "model-b"), "a newly chosen program starts on the first model the server lists for it")
    draft.setTemplate("three", for: "hard", offered: offered)
    #expect(draft.tiers["hard"]?.model == "model-c", "a model the new program also offers is kept")
    draft.setTemplate("four", for: "hard", offered: [])
    #expect(draft.problem == "Choose a model for hard helpers." && draft.policy.difficulties["hard"] == nil, "no model yet: not sent")
    draft.setTemplate("", for: "easy", offered: [])
    #expect(draft.tiers["easy"] == nil, "no program: that difficulty is not allowed")
    draft.setTemplate("two", for: "hard", offered: offered); draft.tiers["hard"]?.model = "model-c"; draft.maxRunning = 2; draft.stopAfterSeconds = 300
    let body = draft.policy.body
    #expect(body["max_running"] as? Int == 2 && body["stop_after_seconds"] as? Int == 300)
    #expect(body["difficulties"] as? [String: [String: String]] == ["medium": ["template": "two", "model": "model-b"], "hard": ["template": "two", "model": "model-c"]])
    // No policy on the server yet: nothing is allowed, and the server's default delay is the starting point.
    let none = HerdrHelperPolicyDraft(try decoded(HerdrHelperSettings.self, #"{"policy":null,"problem":"No helper policy yet.","bounds":{"stop_after_seconds":{"min":5,"max":600,"default":45}}}"#))
    #expect(none.tiers.isEmpty && none.stopAfterSeconds == 45 && none.delays() == [15, 30, 45, 60, 120, 300] && none.policy.difficulties.isEmpty)
    let templates = [HerdrClient.Template(name: "a", description: nil, error: nil, runtime: nil, modelAgent: "x"), HerdrClient.Template(name: "b", description: nil, error: nil, runtime: nil),
                     HerdrClient.Template(name: "c", description: nil, error: "broken", runtime: nil, modelAgent: "x")]
    #expect(HerdrHelperPolicyDraft.templates(in: templates).map(\.name) == ["a"], "only a usable program that takes a model can run helpers")
    #expect(HerdrHelperPolicySection.reason(HerdrClient.Failure.http(404, "x")).contains("needs an update") && HerdrHelperPolicySection.reason(HerdrClient.Failure.http(422, "The server's own sentence.")) == "The server's own sentence.")
}

/// A helper that never answers is stopped after a time the server keeps; the form shows it only for a server that has it.
@Test func theUnansweredStopIsEditedWhenTheServerHasIt() throws {
    let settings = try decoded(HerdrHelperSettings.self, """
    {"policy":{"max_running":3,"stop_after_seconds":60,"stop_unanswered_after_seconds":1800,"difficulties":{"easy":{"template":"one","model":"model-a"}}},
     "problem":null,"bounds":{"max_running":{"min":0,"max":16},"stop_after_seconds":{"min":5,"max":86400,"default":60},"stop_unanswered_after_seconds":{"min":60,"max":604800,"default":1800}}}
    """)
    var draft = HerdrHelperPolicyDraft(settings)
    #expect(draft.stopUnansweredSeconds == 1_800 && draft.stopUnansweredRange == 60...604_800 && draft.policy == settings.policy)
    #expect(draft.unansweredDelays() == [300, 900, 1_800, 3_600, 7_200, 14_400, 28_800, 86_400] && HerdrHelperPolicyDraft.delayLabel(1_800) == "30 minutes")
    draft.stopUnansweredSeconds = 7_200
    #expect(draft.policy.body["stop_unanswered_after_seconds"] as? Int == 7_200 && draft != HerdrHelperPolicyDraft(settings))
    // No policy yet: the server's default is where the form starts. A saved value outside the usual choices is kept.
    let fresh = HerdrHelperPolicyDraft(try decoded(HerdrHelperSettings.self, #"{"policy":null,"bounds":{"stop_unanswered_after_seconds":{"min":60,"max":3600,"default":1200}}}"#))
    #expect(fresh.stopUnansweredSeconds == 1_200 && fresh.unansweredDelays() == [300, 900, 1_200, 1_800, 3_600])
}

/// Helpers are read for the open chat, for a bot that is answering and for a bot that shows some; no other bot is.
@MainActor @Test func helpersAreReadOnlyWhereItIsUseful() throws {
    let store = helperStore()
    let open = Bot(name: "Open", backend: .herdr), busy = Bot(name: "Busy", backend: .herdr), idle = Bot(name: "Idle", backend: .herdr), old = Bot(name: "Old", backend: .mock)
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
    #expect(store.herdrHelperWatch().bots.isEmpty, "a sample agent has none")
}

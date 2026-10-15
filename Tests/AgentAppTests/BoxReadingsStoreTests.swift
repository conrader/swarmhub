import Foundation
import Testing
@testable import AgentApp

// P31 D+E store paths: the quiet Check turns, the readings kept in store.json across a restart, the coding model and
// coding job limit asked in the manager's chat (the recipe rides on the follow-up too), and the models refresh after the
// model log's DONE. Synthetic server only.

/// Jarvis manages a synthetic box; each chat turn gets the next reply.
@MainActor private func readingsStore(url: URL = temporaryStore(), replies: [String]) -> (AppStore, Bot, String) {
    let counter = LockedTrace()
    let (chat, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-box"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in hermes },
                         keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "manager-key", "hermes.mira": "k"]), defaults: isolatedDefaults())
    store.skillLibraryOverride = []
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    let mira = Bot(name: "Mira", backend: .hermes, hermesProfile: "mira")
    store.bots = [jarvis, mira]; store.selectedBot = jarvis
    return (store, jarvis, chat)
}

private func block(_ json: String) -> String { "Done.\n```swarmhub\n\(json)\n```" }
private let modelsLine = #"{"op":"models","list":[{"name":"grok-jarvis","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"gpt-6.1-sol","sub_provider":"openai-codex"},{"name":"mira","model":"grok-4.1","provider":"xai","sub_model":"","sub_provider":""}]}"#
private let capacityLine = #"{"op":"box_capacity","cpus":2,"mem_total_mb":3891,"mem_avail_mb":1380,"disk_free_mb":17400,"load1":"0.42","slots":null,"jobs":[]}"#

private func turns(_ host: String) -> [(input: String, instructions: String)] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { ($0.body?["input"] as? String ?? "", $0.body?["instructions"] as? String ?? "") }
}

@Test @MainActor func checkRunsQuietTurnsAndTheReadingsSurviveARestart() async throws {
    let url = temporaryStore()
    let (store, jarvis, chat) = readingsStore(url: url, replies: [block(modelsLine), block(capacityLine)])
    let target = store.connection(of: jarvis), mira = try #require(store.bots.last)
    #expect(store.subAgentLine(for: mira, delegationOff: false).offersCheck, "no report yet")
    #expect(await store.checkModels(on: target))
    #expect(await store.checkCapacity(on: target))
    #expect(store.subAgentLine(for: jarvis, delegationOff: false).text.hasPrefix("Coding model: gpt-6.1-sol (reported "))
    #expect(store.subAgentLine(for: mira, delegationOff: false).text == "Coding model: same as this bot (grok-4.1)")
    #expect(store.boxReadings(on: target).capacity?.cpus == 2 && store.boxReadings(on: target).capacityAt != nil)
    let sent = turns(chat)
    #expect(sent.count == 2 && sent[0].instructions.contains(#"printf '{"op":"models","list":[%s]}\n'"#) && sent[1].instructions.contains(#""op":"box_capacity""#))
    #expect(!sent[0].instructions.contains("box_capacity") && !sent[1].instructions.contains(#""op":"models""#), "each turn only its recipe")
    #expect(store.bots.allSatisfy { $0.messages.isEmpty }, "quiet turns never land in a chat")

    let reloaded = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: isolatedDefaults())
    #expect(reloaded.boxReadings == store.boxReadings && reloaded.boxReadings[target]?.models?.count == 2)
}

@Test @MainActor func aCheckWithoutTheOpSaysSoAndKeepsTheLastReport() async throws {
    let (store, jarvis, _) = readingsStore(replies: [block(capacityLine), "I could not read it.", block(#"{"op":"box_capacity","cpus":0}"#)])
    let target = store.connection(of: jarvis)
    #expect(await store.checkCapacity(on: target) && store.boxCheckProblems[.capacity(target)] == nil)
    #expect(await store.checkCapacity(on: target) == false && store.boxCheckProblems[.capacity(target)] == BoxReadingsCopy.noAnswer)
    #expect(await store.checkCapacity(on: target) == false, "an out-of-range report is dropped")
    #expect(store.boxReadings(on: target).capacity?.cpus == 2 && store.boxChecks.isEmpty)
}

@Test @MainActor func subAgentChangeIsAskedInTheManagersChatWithTheRecipeOnTheFollowUp() async throws {
    let (store, jarvis, chat) = readingsStore(replies: ["I will set gpt-6.1-sol for mira's sub-agents. OK?", "Done: mira ok."])
    let change = SubAgentModelChange(model: "gpt-6.1-sol", provider: "openai-codex", bots: .some(["mira"]))
    #expect(store.requestSubAgentModel(change, manager: jarvis))
    try await waitUntil { store.isIdle && turns(chat).count == 1 }
    #expect(jarvis.messages.first?.content == "Change the coding model of mira to gpt-6.1-sol (openai-codex).")
    #expect(store.send(text: "yes"))
    try await waitUntil { store.isIdle && turns(chat).count == 2 }
    let sent = turns(chat)
    for turn in sent {
        #expect(turn.instructions.contains("export MODEL=gpt-6.1-sol PROV=openai-codex KM=delegation.model KP=delegation.provider") && turn.instructions.contains("Ask him first"))
    }
    #expect(!store.requestSubAgentModel(SubAgentModelChange(model: "x; id", provider: "p", bots: .all), manager: jarvis), "an invalid change sends nothing")
}

@Test @MainActor func codingLimitIsAskedAndItsCapacityReplyUpdatesTheBlock() async throws {
    let (store, jarvis, chat) = readingsStore(replies: ["Set 2 coding jobs at a time on this box?", block(capacityLine.replacingOccurrences(of: #""slots":null"#, with: #""slots":2"#))])
    let target = store.connection(of: jarvis)
    #expect(store.requestCodingLimit(2, on: target))
    try await waitUntil { store.isIdle && turns(chat).count == 1 }
    #expect(store.send(text: "yes"))
    try await waitUntil { store.isIdle && store.boxReadings(on: target).capacity?.slots == 2 }
    #expect(turns(chat).allSatisfy { $0.instructions.contains("( N=2; D=~/.hermes/swarmhub;") })
    #expect(jarvis.messages.first?.content == "Let this box run 2 coding jobs at a time." && store.managementExchanges[jarvis.id] == nil, "the block closes the exchange")
    #expect(BoxCapacity(try #require(store.boxReadings(on: target).capacity)).line.hasSuffix("2 coding jobs at a time (set by you)"))
}

@Test @MainActor func modelLogDoneAlsoRequestsModels() async throws {
    let (store, jarvis, chat) = readingsStore(replies: [block(modelsLine)])
    let target = store.connection(of: jarvis)
    func reply(_ text: String, readsLog: Bool) -> ChatMessage {
        let message = ChatMessage(role: .assistant, content: text)
        var activity = ToolActivity()
        activity.apply(ToolEvent(phase: .started, name: "terminal", preview: readsLog ? "cat ~/.hermes/swarmhub-model.log" : "ls"), at: .now); message.activity = activity
        return message
    }
    // A reply with a block but no log read (e.g. a description change) refreshes the bots, not the models.
    let other = reply(block(#"{"op":"description","name":"mira","description":"x"}"#), readsLog: false)
    jarvis.messages = [ChatMessage(role: .user, content: "describe mira"), other]
    #expect(!store.refreshModelsAfterRecipe(other, from: jarvis, in: jarvis).isEmpty)
    // A reply that already reports models does not ask again.
    let reported = reply(block(modelsLine), readsLog: true)
    jarvis.messages = [ChatMessage(role: .user, content: "yes"), reported]
    #expect(!store.refreshModelsAfterRecipe(reported, from: jarvis, in: jarvis).isEmpty)
    try await Task.sleep(for: .milliseconds(300))
    #expect(turns(chat).isEmpty)
    // DONE read from the log: one quiet models turn.
    let done = reply("mira ok", readsLog: true)
    jarvis.messages = [ChatMessage(role: .user, content: "yes"), done]
    #expect(!store.refreshModelsAfterRecipe(done, from: jarvis, in: jarvis).isEmpty)
    try await waitUntil { store.boxReadings(on: target).models?.count == 2 }
    #expect(turns(chat).count == 1 && turns(chat)[0].instructions.contains(#""op":"models""#))
}

@Test @MainActor func manageBotsOpensTheSubAgentSheetInsteadOfTheComposer() throws {
    let (store, jarvis, _) = readingsStore(replies: [])
    store.startManagement(.changeSubAgentModel, manager: jarvis, target: "mira")
    #expect(store.subAgentModelRequest?.managerID == jarvis.id && store.subAgentModelRequest?.profile == "mira")
    #expect(store.composerFill == nil && store.managementExchanges[jarvis.id] == nil)
}

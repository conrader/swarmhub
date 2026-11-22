import Foundation
import Testing
@testable import AgentApp

// The summary of a long conversation's older part: a one-off agent on the bot's server writes it, it is kept beside
// the archive, and when it cannot be made the handoff goes with the recent part and the full transcript alone.

private let secret = "synthetic-secret-value-7"

private func permissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

@Test func theOlderPartIsSummarisedByAOneOffAgentThatIsEndedAfterwards() async throws {
    let id = UUID(), name = HerdrClient.compactorName(for: id)
    let bridge = HandoffBridge()
    bridge.answers = { task in task.contains("message 2 of 2") ? "The complete summary." : "A first summary." }
    let files = (1...5).map { HerdrClient.TaskFile(name: "older-part-\($0).md", mime: "text/markdown", data: Data("part \($0)".utf8)) }
    let summary = try await bridge.client().summarise(files, name: name, template: nil, model: nil, limit: .seconds(600))
    #expect(summary == "The complete summary.", "the reply to the last message is the summary")
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch-with-files", "message-with-files", "end"])
    #expect(sent.allSatisfy { $0.agent == name } && bridge.liveNames.isEmpty, "one agent of its own name, ended afterwards")
    #expect(sent[0].files.keys.sorted() == ["older-part-1.md", "older-part-2.md", "older-part-3.md", "older-part-4.md"] && sent[1].files == ["older-part-5.md": "part 5"])
    #expect(sent[0].text.contains("You are preparing a handover") && sent[0].workspaceID == nil, "not in the bot's own folder")
    #expect(sent.allSatisfy { $0.text.utf8.count <= 12 * 1024 && $0.files.count <= 4 }, "within what one message may carry")
    // One that an earlier run left behind is ended first, so the files never go into its old session.
    let again = HandoffBridge()
    again.seed(agent: name, rows: [("task", "an old task"), ("reply", "an old reply")])
    #expect(try await again.client().summarise(Array(files.prefix(1)), name: name, template: nil, model: nil, limit: .seconds(600)) == "ok")
    #expect(again.sent.map(\.route) == ["end", "launch-with-files", "end"] && again.liveNames.isEmpty)
    // A server that will not start it: the error comes back, and nothing is left running.
    let refusing = HandoffBridge(); refusing.refusesLaunch = { _ in true }
    await #expect(throws: (any Error).self) { try await refusing.client().summarise(files, name: name, template: nil, model: nil, limit: .seconds(600)) }
    #expect(refusing.sent.isEmpty && refusing.liveNames.isEmpty)
}

@Test func theOneOffAgentIsNeverTakenForABotsAgent() throws {
    let id = UUID()
    let compactor = HerdrClient.compactorName(for: id), bot = HerdrBackend.agentName(botName: "Ada", botID: id)
    let namesake = HerdrBackend.agentName(botName: "Handoff", botID: id)
    let group = try #require(HerdrBackend.groupRuntimeName(sessionID: GroupRouting.sessionID(group: UUID(), bot: id), botID: id))
    #expect(compactor.count == 20 && compactor.hasPrefix("handoff-") && compactor.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, "a name the server accepts")
    #expect(compactor == HerdrClient.compactorName(for: id) && compactor != HerdrClient.compactorName(for: UUID()))
    let client = HerdrClient(baseURL: URL(string: "http://test.invalid")!, token: "t")
    func workspace(_ names: [String]) throws -> HerdrClient.Workspace {
        let agents: [[String: Any]] = names.enumerated().map { index, name in ["address": "t\(index)", "name": name, "state": "live", "created_ms": index + 1] }
        let json: [String: Any] = ["core": "c", "version": "1", "agents": agents, "templates": [Any]()]
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HerdrClient.Workspace.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let alone = try workspace([compactor])
    for other in [bot, namesake, group] {
        let others = try workspace([other])
        #expect(client.liveAgent(named: other, in: alone) == nil, "\(other) is not found in the one-off agent")
        #expect(client.liveAgent(named: compactor, in: others) == nil, "the one-off agent is not found in \(other)")
        #expect(HerdrClient.suffix(of: other) != HerdrClient.suffix(of: compactor))
    }
    let both = try workspace([compactor, bot])
    #expect(client.liveAgent(named: bot, in: both)?.name == bot && client.liveAgent(named: compactor, in: both)?.name == compactor)
}

@Test @MainActor func aLongConversationIsSummarisedOnceAndTheSummaryIsKeptBesideTheArchive() async throws {
    let bridge = HandoffBridge()
    bridge.answers = { task in
        if task.contains("You are preparing a handover") { return "They planned the launch. The person likes short answers. password: \(secret)" }
        return task.contains("[SwarmHub handoff") ? "It stood at question 120." : "the answer"
    }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 120, bytes: 400))
    let compactor = HerdrClient.compactorName(for: bot.id), agent = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    #expect(store.send(text: "Where were we?"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffRecord(for: bot) != nil }
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch-with-files", "end", "launch-with-files", "message"])
    #expect(sent.map(\.agent) == [compactor, compactor, agent, agent], "the summary is written and its agent ended before the bot's agent starts")
    #expect(sent[0].files.keys.sorted() == ["older-part-1.md"] && sent[0].files["older-part-1.md"]?.contains("question 1 end") == true)
    #expect(sent[0].files["older-part-1.md"]?.contains("question 120 end") == false, "only the older part is summarised")
    let handoff = try #require(sent[2].files["grok-handoff.md"])
    #expect(handoff.contains("## Summary of the older part (152 messages, #1 to #152)") && handoff.contains("They planned the launch.") && handoff.contains("question 120 end"))
    #expect(!handoff.contains(secret) && !sent[2].text.contains(secret) && sent[2].text.contains("They planned the launch."), "the note carries the summary too, filtered")
    #expect(sent[3].text.hasSuffix("Where were we?") && bot.messages.last(where: { $0.role == .assistant })?.content == "the answer")
    // Kept beside the archive, private, filtered.
    let url = store.grokHistory.handoffURL(for: bot.id)
    let cache = try #require(GrokHandoffCache.load(url))
    #expect(cache.summary.hasPrefix("They planned the launch.") && !cache.summary.contains(secret) && cache.from == 1 && cache.through == 152 && cache.messages == 152)
    let onDisk = try String(contentsOf: url, encoding: .utf8)
    #expect(try permissions(url) == 0o600)
    #expect(!onDisk.contains(secret) && onDisk.contains("They planned the launch."))
    let record = try #require(store.grokHandoffRecord(for: bot))
    #expect(record.summarised && record.older == 152 && record.recent == 88 && store.grokHandoffs.summaries.isEmpty && store.grokHandoffState(for: bot.id).summaryHold == nil)
    #expect(store.grokHandoffLine(for: bot).hasPrefix("Handed over to Ada · summary of 152 + last 88 messages · "))
    // A new agent of the bot is handed the conversation again, with the summary that was kept: none is made twice.
    #expect(try await store.restartHerdrAgent(for: bot))
    #expect(store.send(text: "And now?"))
    try await waitUntil { store.runningTurns.isEmpty }
    let later = Array(bridge.sent.dropFirst(4))
    #expect(later.map(\.route) == ["end", "launch-with-files", "message"] && later.allSatisfy { $0.agent == agent })
    #expect(later[1].files["grok-handoff.md"] == handoff && bot.messages.filter { $0.role == .system }.count == 1, "the same bytes, and the chat said it once")
}

@Test @MainActor func aSummaryThatCannotBeMadeLeavesTheRecentPartAndTheFullTranscript() async throws {
    let bridge = HandoffBridge()
    bridge.answers = { task in task.contains("[SwarmHub handoff") ? "It stood at question 120." : "the answer" }
    bridge.refusesLaunch = { $0.hasPrefix("handoff-") }
    let (store, bot) = try handoffStore(bridge, lines: handoffConversation(exchanges: 120, bytes: 400))
    let agent = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
    #expect(store.send(text: "Where were we?"))
    try await waitUntil { store.runningTurns.isEmpty && store.grokHandoffRecord(for: bot) != nil }
    let sent = bridge.sent
    try #require(sent.map(\.route) == ["launch-with-files", "message"])
    #expect(sent.allSatisfy { $0.agent == agent } && bridge.liveNames == [agent], "no one-off agent is left behind")
    let handoff = try #require(sent[0].files["grok-handoff.md"])
    #expect(handoff.contains("The older part is not summarised here") && !handoff.contains("## Summary of the older part") && handoff.contains("question 120 end") && !handoff.contains("question 1 end"))
    #expect(sent[0].files["grok-history-full.md"]?.contains("question 1 end") == true, "the older part is in the full transcript")
    #expect(sent[0].text.contains("The last messages, in case you cannot open the files:") && sent[1].text.hasSuffix("Where were we?"))
    #expect(!FileManager.default.fileExists(atPath: store.grokHistory.handoffURL(for: bot.id).path) && store.grokHandoffs.summaries.isEmpty)
    #expect(store.grokHandoffState(for: bot.id).summaryHold?.tooLong == false && store.grokOffersSummary(for: bot), "the failure is kept, and the header offers to try again")
    let record = try #require(store.grokHandoffRecord(for: bot))
    #expect(!record.summarised && record.older == 152 && store.grokHandoffLine(for: bot).contains("without a summary"))
}

@Test @MainActor func theSavedSummaryIsPrivateStaysOutOfTheStoreFileAndGoesWithTheArchive() throws {
    let storeURL = temporaryStore()
    let lines = handoffConversation(exchanges: 5) + [handoffLine(11, "user", "a line only the archive holds")]
    let (store, bot) = try handoffStore(HandoffBridge(), lines: lines, storeURL: storeURL)
    let url = store.grokHistory.handoffURL(for: bot.id)
    #expect(url.lastPathComponent == "\(bot.id.uuidString.lowercased()).handoff.json" && url.deletingLastPathComponent().path == store.grokHistory.fileURL(for: bot.id).deletingLastPathComponent().path)
    let made = GrokHandoffCache(summary: "  a summary only the cache holds, password: \(secret)  ", from: 1, through: 4, messages: 4, template: "tpl-one", model: "",
                                madeAt: Date(timeIntervalSince1970: 1_700_000_000))
    try made.save(to: url, directory: store.grokHistory.directory)
    #expect(try permissions(url) == 0o600)
    let loaded = try #require(GrokHandoffCache.load(url))
    #expect(loaded == made && loaded.summary.hasPrefix("a summary only the cache holds") && !loaded.summary.contains(secret) && loaded.through == 4)
    // A file some older version wrote unfiltered is filtered when it is loaded.
    let raw = "{\"summary\":\"mentioned password: \(secret) once\",\"from\":1,\"through\":4,\"messages\":4,\"template\":\"\",\"model\":\"\",\"madeAt\":\"2026-01-02T03:04:05Z\"}"
    try Data(raw.utf8).write(to: url)
    let filtered = try #require(GrokHandoffCache.load(url))
    #expect(!filtered.summary.contains(secret) && filtered.summary.contains(GrokRedactor.marker) && filtered.summary.hasPrefix("mentioned"))
    // The store file holds neither the transcript nor the summary.
    try store.saveThrowing()
    let saved = try String(contentsOf: storeURL, encoding: .utf8)
    #expect(saved.contains("source-one") && !saved.contains("only the archive holds") && !saved.contains("only the cache holds") && !saved.contains("mentioned") && !saved.contains(secret))
    // It goes when the archive goes.
    store.grokHistory.remove(bot.id)
    #expect(!FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: store.grokHistory.fileURL(for: bot.id).path))
    #expect(GrokHandoffCache.load(url) == nil)
}

@Test func aTurnWaitsForASummaryOnlySoLong() async {
    let made = GrokHandoffCache(summary: "A summary.", from: 1, through: 2, messages: 2, template: "", model: "", madeAt: Date(timeIntervalSince1970: 0))
    let done = Task<GrokHandoffCache?, Never> { made }
    #expect(await AppStore.waited(done, upTo: .seconds(600)) == made, "one that is there is taken at once")
    // One that never comes: the wait ends by itself, and the work goes on until it is cancelled.
    let never = Task<GrokHandoffCache?, Never> { await hangUntilCancelled(); return nil }
    #expect(await AppStore.waited(never, upTo: .milliseconds(1)) == nil && !never.isCancelled)
    never.cancel()
}

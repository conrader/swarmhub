import Foundation
import Testing
@testable import AgentApp

// A Herdr turn followed on the bridge's event stream, with the polling routes as the fallback.

private let snapshotJSON = #"{"core":"c","address":"t1","created_ms":5,"agent":{"address":"t1","created_ms":5,"name":"x","state":"live","status":{"state":"working"},"template":"one"},"history":{"items":[{"id":11,"kind":"task","state":"sent","text":"zażółć"}],"before":null},"draft":{"id":"m1","text":"Wor"},"tools":[{"seq":3,"tool":"Bash","detail":"old","finished":true,"failed":false},{"seq":4,"tool":"Bash","detail":"ls","finished":false,"failed":false}],"helpers":null}"#

private func sse(_ name: String, _ data: String) -> String { "event: \(name)\ndata: \(data)\n\n" }
private func row(_ id: Int, _ kind: String, _ text: String) -> HerdrClient.Item { HerdrClient.Item(id: id, kind: kind, text: text) }
private func call(_ seq: UInt64, finished: Bool) -> HerdrClient.ToolCall { .init(seq: seq, tool: "Bash", detail: seq == 4 ? "ls" : "old", finished: finished, failed: false) }

/// Collects what a turn reports from wherever it is called.
private final class Heard<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Value] = []
    func add(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}

/// A bridge that answers each connection of the stream with the next script: the text to send, then whether the
/// connection closes cleanly (nil) or fails. A connection past the last script stays open and silent.
private func scripted(_ connections: [(text: String, error: Error?)], requests: Heard<String>) -> @Sendable (URLRequest) -> AsyncThrowingStream<Data, Error> {
    { request in
        requests.add(request.url?.query ?? "")
        let index = requests.all.count - 1
        return AsyncThrowingStream { continuation in
            guard index < connections.count else { return }
            // Cut into small pieces, as a network would.
            let bytes = Array(connections[index].text.utf8)
            for start in stride(from: 0, to: bytes.count, by: 37) { continuation.yield(Data(bytes[start..<min(start + 37, bytes.count)])) }
            if let error = connections[index].error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

private func streamClient(_ source: @escaping @Sendable (URLRequest) -> AsyncThrowingStream<Data, Error>) -> HerdrClient {
    var client = HerdrClient(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "t")
    client.byteSource = source; client.pollInterval = .milliseconds(20); client.agentCheckInterval = .milliseconds(40)
    return client
}

private let turn = HerdrClient.Turn(core: "c", address: "t1", createdMs: 5, after: 10, launched: false, afterTool: 3)

@Test func eventsAreReadFromBytesCutAnywhere() {
    let wire = sse("snapshot", snapshotJSON).replacingOccurrences(of: "\n\n", with: "\r\n\r\n") + ": heartbeat\n\n" + sse("draft_append", #"{"id":"m1","offset":3,"text":"king żółć"}"#)
        + sse("later_kind", "{}") + sse("end", #"{"reason":"gone"}"#)
    var parser = HerdrSSEParser(), frames: [HerdrSSEParser.Frame] = []
    for byte in Data(wire.utf8) { frames += parser.feed(Data([byte])) }
    var whole = HerdrSSEParser()
    #expect(frames.count == 5 && frames[1] == .comment("heartbeat") && whole.feed(Data(wire.utf8)) == frames, "one byte at a time or all at once, the same frames")
    let events: [HerdrEvent?] = frames.map { if case .event(let name, let data) = $0 { return HerdrEvent.decode(name: name, data: data) } else { return .heartbeat } }
    guard case .snapshot(let snapshot)? = events[0] else { Issue.record("the snapshot decodes"); return }
    #expect(snapshot.core == "c" && snapshot.agent?.status?.state == "working" && snapshot.rows == [HerdrClient.Item(id: 11, kind: "task", text: "zażółć", state: "sent")] && snapshot.draft == .init(id: "m1", text: "Wor") && snapshot.tools.map(\.seq) == [3, 4] && snapshot.helpers == nil)
    #expect(events[2] == .draftAppend(id: "m1", offset: 3, text: "king żółć") && events[3] == nil && events[4] == .end(reason: "gone"), "an event this build does not know is skipped")
    #expect(HerdrEvent.decode(name: "draft", data: "null") == .draft(nil) && HerdrEvent.decode(name: "helpers", data: "null") == .helpers(nil) && HerdrEvent.decode(name: "tool", data: #"{"seq":4,"tool":"Bash","detail":"ls","finished":true,"failed":false}"#) == .tool(call(4, finished: true)))
    var log = HerdrClient.HelperLog(), draftID: String?
    for event in events.compactMap({ $0 }) { #expect(log.apply(event, draftID: &draftID)) }
    #expect(log.tasks == [HerdrClient.Item(id: 11, kind: "task", text: "zażółć", state: "sent")] && log.tools.map(\.seq) == [3, 4] && log.draft == "Working żółć" && !log.apply(.draftAppend(id: "other", offset: 0, text: "x"), draftID: &draftID), "a helper's log is built from the same events")
}

/// One follower decides for the stream and for polling: what to show, when the reply is complete, when to give up.
@Test func theFollowerDecidesTheSameHoweverItLearns() throws {
    let start = ContinuousClock.now
    var follower = HerdrTurnFollower(after: 10, afterTool: 3)
    follower.take(rows: [row(9, "reply", "old"), row(11, "task", "do it")]); follower.take(tools: [call(3, finished: true), call(4, finished: false)]); follower.take(draft: .init(id: "m1", text: "Wor"))
    #expect(follower.judgeSaved(now: start) == .waiting && follower.drain() == [.tool(call(4, finished: false), isNew: true), .partial("Wor")], "earlier rows and calls are not the turn's")
    #expect(follower.append(draft: "m1", offset: 3, text: "king") && !follower.append(draft: "m1", offset: 3, text: "x") && !follower.append(draft: "m2", offset: 7, text: "x"), "appended text must fit what is held")
    // The same call heard again from the other route: its end is reported once, its start never again.
    follower.take(tools: [call(4, finished: false), call(4, finished: true)]); follower.take(tools: [call(4, finished: true)]); follower.take(draftText: "Working")
    #expect(follower.judgeSaved(now: start) == .waiting && follower.drain() == [.tool(call(4, finished: true), isNew: false), .partial("Working")])
    follower.take(rows: [row(12, "reply", "Done.")])
    #expect(follower.judgeSaved(now: start) == .reply("Done.") && follower.newestRow == 12)

    var steered = HerdrTurnFollower(after: 0)
    steered.take(rows: [row(1, "task", "a"), row(2, "task", "b"), row(3, "reply", "first")])
    #expect(steered.judgeSaved(now: start) == .waiting && steered.drain() == [.partial("first")] && steered.wantsAgentNow)
    #expect(steered.judgeSaved(now: start + .seconds(4)) == .waiting && steered.judgeSaved(now: start + .seconds(6)) == .reply("first"), "a steered message with no reply of its own ends the turn after a short wait")
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    func agent(_ state: String) throws -> HerdrClient.Agent { try decoder.decode(HerdrClient.Agent.self, from: Data(#"{"address":"t1","created_ms":5,"name":"x","state":"live","template":"one","status":{"state":"\#(state)"}}"#.utf8)) }
    var twice = HerdrTurnFollower(after: 0)
    twice.take(rows: [row(1, "task", "a"), row(2, "task", "b"), row(3, "reply", "first")]); _ = twice.judgeSaved(now: start)
    twice.take(agent: try agent("working")); _ = twice.judgeAgent(now: start + .seconds(4))
    #expect(twice.judgeSaved(now: start + .seconds(8)) == .waiting, "an agent working again after a reply is waited for")
    twice.take(rows: [row(4, "reply", "second")])
    let both = try twice.ended()
    #expect(twice.judgeSaved(now: start + .seconds(9)) == .reply("first\n\nsecond") && both == "first\n\nsecond")

    var quiet = HerdrTurnFollower(after: 0, quietLimit: .seconds(45))
    quiet.take(rows: [row(1, "task", "a")]); quiet.take(agent: try agent("done"))
    #expect(quiet.judgeAgent(now: start) == .waiting && quiet.drain() == [.status(.delivered(program: nil))] && quiet.judgeAgent(now: start + .seconds(44)) == .waiting && quiet.judgeAgent(now: start + .seconds(46)) == .failed(.silent))
    quiet.take(agent: try agent("working"))
    #expect(quiet.judgeAgent(now: start + .seconds(50)) == .waiting && quiet.drain() == [.status(.working(program: nil))], "working again clears the quiet count")
    #expect(throws: HerdrClient.Failure.ended) { try quiet.ended() }
}

/// The whole of a turn on one connection: the reply as it grows, each tool step once, the saved reply at the end.
@Test func aTurnIsFollowedOnTheStream() async throws {
    let requests = Heard<String>(), partials = Heard<String>(), tools = Heard<String>(), statuses = Heard<HerdrTurnStatus>(), notes = Heard<HerdrClient.LiveNote>()
    let stream = sse("snapshot", snapshotJSON) + sse("draft_append", #"{"id":"m1","offset":3,"text":"king"}"#) + sse("tool", #"{"seq":4,"tool":"Bash","detail":"ls","finished":true,"failed":false}"#)
        + ": heartbeat\n\n" + sse("history", #"{"id":12,"kind":"reply","state":"received","text":"Done."}"#) + sse("draft", "null")
    let client = streamClient(scripted([(stream, nil)], requests: requests))
    let reply = try await client.reply(to: turn, status: { statuses.add($0) }, tool: { tools.add("\($0.seq) \($1) \($0.finished)") }, partial: { partials.add($0) }, live: { notes.add($0) })
    #expect(reply == "Done." && requests.all == ["after=10"], "one connection, resumed from the row before the turn")
    #expect(partials.all == ["Wor", "Working"] && tools.all == ["4 true false", "4 false true"] && statuses.all == [.working(program: nil)])
    #expect(notes.all.first == .following(true) && notes.all.contains(.helpers(nil)) && notes.all.last == .following(false))
}

/// A stream that breaks is opened again from the newest row seen; text that does not fit makes it connect again too.
/// Nothing is shown twice.
@Test func aBrokenStreamIsResumedAndNothingIsShownTwice() async throws {
    let requests = Heard<String>(), partials = Heard<String>(), tools = Heard<String>()
    let first = sse("snapshot", snapshotJSON) + sse("history", #"{"id":12,"kind":"task","state":"pending","text":"and this"}"#)
    // Text for another length than the reader holds: it must not be appended.
    let second = sse("snapshot", snapshotJSON.replacingOccurrences(of: #"{"items":[{"id":11,"kind":"task","state":"sent","text":"zażółć"}],"before":null}"#, with: #"{"items":[],"before":null}"#).replacingOccurrences(of: #""text":"Wor""#, with: #""text":"Working""#))
        + sse("draft_append", #"{"id":"m1","offset":99,"text":"lost"}"#)
    let third = sse("snapshot", snapshotJSON.replacingOccurrences(of: #"{"items":[{"id":11,"kind":"task","state":"sent","text":"zażółć"}],"before":null}"#, with: #"{"items":[{"id":13,"kind":"reply","text":"One."},{"id":14,"kind":"reply","text":"Two."}],"before":null}"#)
        .replacingOccurrences(of: #""finished":false"#, with: #""finished":true"#))
    let client = streamClient(scripted([(first, URLError(.networkConnectionLost)), (second, nil), (third, nil)], requests: requests))
    let reply = try await client.reply(to: turn, tool: { tools.add("\($0.seq) \($1) \($0.finished)") }, partial: { partials.add($0) })
    #expect(reply == "One.\n\nTwo." && requests.all == ["after=10", "after=12", "after=12"], "each new connection asks only for rows after the newest one seen")
    #expect(tools.all == ["4 true false", "4 false true"] && partials.all == ["Wor", "Working"], "the step started once and ended once; the text was never doubled")
}

/// A session that ends answers its snapshot and `end`: the turn takes the replies it saved, or says that it ended.
@Test func anEndedSessionEndsTheTurn() async throws {
    let over = sse("snapshot", snapshotJSON) + sse("end", #"{"reason":"ended"}"#)
    await #expect(throws: HerdrClient.Failure.ended) { try await streamClient(scripted([(over, nil)], requests: Heard<String>())).reply(to: turn) }
    let saved = sse("snapshot", snapshotJSON) + sse("history", #"{"id":12,"kind":"reply","text":"Last words."}"#) + sse("end", #"{"reason":"ended"}"#)
    let last = try await streamClient(scripted([(saved, nil)], requests: Heard<String>())).reply(to: turn)
    #expect(last == "Last words.")
}

/// A bridge without the stream, or one whose stream keeps failing, is polled: the polling routes give the same turn.
@Test func withoutAStreamTheTurnIsPolled() async throws {
    let polls = Heard<String>()
    let (host, session) = MockHTTPProtocol.serve { request in
        let path = request.url?.path ?? ""
        polls.add(path)
        if path.hasSuffix("/draft") {
            let ended: [String: Any] = ["seq": 4, "tool": "Bash", "detail": "ls", "finished": true, "failed": false]
            return (200, ["draft": NSNull(), "tools": [ended]] as [String: Any])
        }
        if path.hasPrefix("/api/history/") {
            // The reply is there from the third read on.
            let replied = polls.all.filter { $0.hasPrefix("/api/history/") && !$0.hasSuffix("/draft") }.count >= 3
            let task: [String: Any] = ["id": 11, "kind": "task", "text": "do it"], reply: [String: Any] = ["id": 12, "kind": "reply", "text": "Polled."]
            return (200, ["items": replied ? [task, reply] : [task], "before": NSNull()] as [String: Any])
        }
        if path == "/api/workspace" {
            let agent: [String: Any] = ["address": "t1", "created_ms": 5, "name": "x", "state": "live", "template": "one", "status": ["state": "working"]]
            return (200, ["core": "c", "version": "1", "templates": [Any](), "agents": [agent]] as [String: Any])
        }
        return (404, ["error": "no route"] as [String: Any])
    }
    func client(_ source: @escaping @Sendable (URLRequest) -> AsyncThrowingStream<Data, Error>) -> HerdrClient {
        var client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t")
        client.session = session; client.byteSource = source; client.pollInterval = .milliseconds(10); client.agentCheckInterval = .milliseconds(20)
        return client
    }
    // No such route (an older bridge): no second try, straight to polling.
    let opened = Heard<String>(), tools = Heard<String>(), notes = Heard<HerdrClient.LiveNote>()
    let older = client(scripted([("", HerdrClient.Failure.http(404, "no route"))], requests: opened))
    let fromOlder = try await older.reply(to: turn, tool: { tools.add("\($0.seq) \($1) \($0.finished)") }, live: { notes.add($0) })
    #expect(fromOlder == "Polled." && opened.all.count == 1 && tools.all == ["4 true true"] && !notes.all.contains(.following(true)) && polls.all.contains("/api/workspace"))
    // Every stream taken (429) reads the same way.
    let full = Heard<String>()
    let fromFull = try await client(scripted([("", HerdrClient.Failure.http(429, "too many"))], requests: full)).reply(to: turn)
    #expect(fromFull == "Polled." && full.all.count == 1)
    // A network that fails each time: tried `streamAttempts` times, then polled.
    let tries = Heard<String>()
    var flaky = client(scripted(Array(repeating: ("", URLError(.networkConnectionLost) as Error?), count: 5), requests: tries))
    flaky.streamAttempts = 2
    let fromFlaky = try await flaky.reply(to: turn)
    #expect(fromFlaky == "Polled." && tries.all.count == 2)
    // A stream that showed the step and then died for good: polling takes over and does not show the step's start again.
    let seen = Heard<String>(), dying = Heard<String>()
    var midway = client(scripted([(sse("snapshot", snapshotJSON), URLError(.networkConnectionLost)), ("", URLError(.networkConnectionLost)), ("", URLError(.networkConnectionLost))], requests: dying))
    midway.streamAttempts = 2
    let fromMidway = try await midway.reply(to: turn, tool: { seen.add("\($0.seq) \($1) \($0.finished)") })
    #expect(fromMidway == "Polled." && seen.all == ["4 true false", "4 false true"] && dying.all == ["after=10", "after=11"], "the stream's step is ended by the poll, not started again")
    // Told to poll: no stream is opened at all.
    let never = Heard<String>()
    var plain = client(scripted([], requests: never)); plain.following = .polling
    let fromPlain = try await plain.reply(to: turn)
    #expect(fromPlain == "Polled." && never.all.isEmpty)
}

/// A turn on the stream keeps its bot's helper rows current and takes the bot out of the helper poll meanwhile.
@MainActor @Test func aStreamedTurnBringsItsBotsHelpers() throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let bot = Bot(name: "Jarvis", backend: .herdr); store.bots = [bot]; store.selectedBot = bot
    #expect(store.herdrHelperWatch().bots == [bot])
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    let list = try decoder.decode(HerdrClient.Helpers.self, from: Data(#"{"core":"c","parent":{"address":"t1","created_ms":5},"limit":3,"helpers":[{"address":"t2","created_ms":6,"name":"probe","state":"live","status":{"state":"working"}}]}"#.utf8))
    store.herdrLive(.following(true), botID: bot.id); store.herdrLive(.helpers(list), botID: bot.id)
    #expect(store.herdrHelpers[bot.id] == list && store.herdrHelperWatch().bots.isEmpty, "the stream brings them; the poll leaves the bot out")
    store.herdrLive(.helpers(nil), botID: bot.id)
    #expect(store.herdrHelpers[bot.id] == nil, "helpers the stream no longer lists leave the screen")
    store.herdrLive(.helpers(list), botID: bot.id); store.herdrLive(.following(false), botID: bot.id)
    #expect(store.herdrHelperWatch().bots == [bot] && store.herdrHelperWatch().often, "after the turn the poll looks after them again")
}

@MainActor @Test func aCompletedRunKeepsItsObservedActivityWithTheReply() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Review", backend: .herdr)
    let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
    let stream = AsyncThrowingStream<AgentEvent, Error> { events in
        events.yield(.launchModel("Sol"))
        events.yield(.replace("Ready"))
        events.yield(.runActivity(seconds: 4, tools: 2))
        events.yield(.completed)
        events.finish()
    }
    _ = try await store.consumeTurn(stream, assistant: reply, bot: bot)
    let saved = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(reply))
    #expect(saved.runSummary?.line == "Sol · 4 s · 2 tool calls")
    let old = ChatMessage(role: .assistant, content: "Earlier reply")
    #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(old)).runSummary == nil)
}

import Foundation
import Testing
@testable import AgentApp

// P16 Part 2: truthful turn state. Synthetic text only.

@Test func turnStateCodingKeepsOldStoresAndSurvivesUnknownValues() throws {
    // Untouched rows encode byte-identically (the key is written only when set).
    let plain = ChatMessage(id: UUID(), role: .assistant, content: "hi", createdAt: Date(timeIntervalSince1970: 1))
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(plain)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("turnState"))
    #expect(try encoder.encode(JSONDecoder().decode(ChatMessage.self, from: encoded)) == encoded)
    // Round trip.
    let stamped = ChatMessage(role: .assistant, content: "", turnState: .notSent)
    #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(stamped)).turnState == .notSent)
    // A pre-P16 row decodes with nil; a future value and a malformed round decode to nil without losing the store.
    let id = UUID(), group = UUID(), bot = UUID()
    let store = """
    {"version":2,"bots":[],"groups":[{"id":"\(group)","name":"G","memberIDs":["\(bot)"],"messages":[
      {"id":"\(id)","role":"assistant","content":"a","createdAt":1,"presentation":"text","metadata":{},"reactions":[],"turnState":"future"},
      {"id":"\(UUID())","role":"assistant","content":"b","createdAt":1,"presentation":"text","metadata":{},"reactions":[]}],
      "unreadCount":0,"manualUnread":false,"isHidden":false,"isMuted":false,"sessions":{},"grokHistoryCount":0,"createdAt":1,"round":{"remaining":"nope"}}]}
    """
    let file = try StoreFile.decode(Data(store.utf8))
    #expect(file.groups.count == 1 && file.groups[0].messages.map(\.turnState) == [nil, nil] && file.groups[0].round == nil)
    let round = GroupRound(userMessageID: id, remaining: [bot], active: nil)
    let chat = GroupChat(name: "G", memberIDs: [bot]); chat.round = round
    #expect(try JSONDecoder().decode(GroupChat.self, from: JSONEncoder().encode(chat)).round == round)
    #expect(!String(decoding: try JSONEncoder().encode(GroupChat(name: "G", memberIDs: [bot])), as: UTF8.self).contains("round"))
}

/// A backend whose stream ends the way the test asks.
actor EndingBackend: AgentBackend {
    nonisolated let kind = BackendKind.herdr
    enum Ending: Sendable { case complete, eof, boxError, throwBeforeHeaders(URLError.Code), cutAfterToken, refuse(Int) }
    let ending: Ending
    init(_ ending: Ending) { self.ending = ending }
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        let ending = ending
        if case .throwBeforeHeaders(let code) = ending { throw StreamBreak(delivered: false, underlying: URLError(code)) }
        if case .refuse(let status) = ending { throw BackendError.http(status, "refused") }
        return AsyncThrowingStream { continuation in
            continuation.yield(.token("partial words"))
            switch ending {
            case .complete: continuation.yield(.completed); continuation.finish()
            case .eof: continuation.finish()
            case .boxError: continuation.yield(.failed("box failed")); continuation.finish()
            case .cutAfterToken: continuation.finish(throwing: StreamBreak(delivered: true, underlying: URLError(.networkConnectionLost)))
            default: continuation.finish()
            }
        }
    }
    func cancel(sessionID: String) async throws -> StopOutcome { .requested }
    func testConnection() async throws -> String { "ok" }
}

@MainActor private func endingStore(_ ending: EndingBackend.Ending) -> (AppStore, Bot) {
    let backend = EndingBackend(ending)
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Echo", backend: .herdr, sessionID: "s-echo"); store.bots = [bot]; store.selectedBot = bot
    return (store, bot)
}

@MainActor @Test func everyEndingStampsTheRowAndFailuresLeaveAWarningLine() async throws {
    let cases: [(EndingBackend.Ending, TurnState, Bool, String?)] = [
        (.complete, .finished, false, nil), (.eof, .incomplete, true, nil), (.boxError, .incomplete, true, "Echo: box failed"),
        (.cutAfterToken, .incomplete, true, "offline"), (.throwBeforeHeaders(.timedOut), .notSent, true, "timeout"),
        (.throwBeforeHeaders(.notConnectedToInternet), .notSent, true, "offline"), (.refuse(401), .notSent, true, "refused"),
    ]
    for (ending, state, warns, alertOrWhy) in cases {
        let (store, bot) = endingStore(ending)
        #expect(store.send(text: "question"))
        try await waitUntil { !store.anyTurnRunning }
        let reply = try #require(bot.messages.first { $0.role == .assistant })
        #expect(reply.turnState == state, "\(ending)")
        #expect(bot.messages.count == (warns ? 3 : 2), "the placeholder is never deleted; one warning line per failure (\(ending))")
        if warns {
            let line = try #require(bot.messages.last)
            #expect(line.role == .system && line.metadata["tone"] == "warning" && line.content.hasPrefix("Echo: "))
        }
        if state == .notSent { #expect(reply.metadata["why"] == alertOrWhy) }
        // uxfix1: a dropped, timed-out or offline turn never raises the modal alert (its row and warning line say it).
        let transient: Bool
        switch ending { case .eof, .cutAfterToken, .throwBeforeHeaders: transient = true; default: transient = false }
        if transient { #expect(store.errorMessage == nil && store.modalErrorMessage == nil, "no alert for \(ending)") }
        else if state != .finished { #expect(store.errorMessage != nil, "D3: the alert stays for the user's own sends") }
        #expect((AvatarReactions.shared.completions[bot.id] != nil) == (state == .finished), "only finished completes and notifies")
        if case .boxError = ending { #expect(store.errorMessage == "box failed") }
    }
}

@MainActor @Test func aRepeatedWarningIsNotWrittenTwiceInARow() async throws {
    let (store, bot) = endingStore(.eof)
    store.addWarning("Echo: same", in: bot, after: nil); store.addWarning("Echo: same", in: bot, after: nil)
    #expect(bot.messages.filter { $0.content == "Echo: same" }.count == 1)
}

@MainActor @Test func stopMarksTheRowStoppedAtOnce() async throws {
    let backend = TestBackend(streamMode: .longRunning)
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let bot = Bot(name: "Long", backend: .herdr, sessionID: "s-long"); store.bots = [bot]; store.selectedBot = bot
    store.send(text: "go")
    try await waitUntil { bot.messages.last?.content == "running" }
    store.stop()
    #expect(bot.messages.first { $0.role == .assistant }?.turnState == .stopped, "set synchronously in stop()")
    try await waitUntil { !store.anyTurnRunning }
    #expect(bot.messages.first { $0.role == .assistant }?.turnState == .stopped && bot.messages.first { $0.role == .assistant }?.content == "running")
}

@Test func classificationTablePinsEveryRow() {
    func classify(_ error: Error) -> TurnOutcome { TurnOutcome.classify(.error(error)) }
    // Terminal event.
    #expect(TurnOutcome.classify(.completed) == .init(state: .finished))
    // The user pressed Stop.
    #expect(TurnOutcome.classify(.stoppedByUser).state == .stopped && TurnOutcome.classify(.stoppedByUser).round == .continues)
    // Certainly unsent: offline class stops the rest; HTTP and refusals continue.
    for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed] {
        let outcome = classify(URLError(code))
        #expect(outcome.state == .notSent && outcome.why == "offline" && !outcome.ambiguous && outcome.round == .stopsRest(why: "offline"))
    }
    for status in [401, 403, 409, 422, 429] {
        let outcome = classify(BackendError.http(status, "no"))
        #expect(outcome.state == .notSent && outcome.why == "refused" && !outcome.ambiguous && outcome.round == .continues)
    }
    #expect(classify(StreamBreak(delivered: false, underlying: URLError(.timedOut), requestStarted: false)).ambiguous == false, "metrics say it never started")
    // Ambiguous before the headers.
    #expect(classify(StreamBreak(delivered: false, underlying: URLError(.timedOut))) == .init(state: .notSent, why: "timeout", ambiguous: true, round: .stopsRest(why: "timeout"), reason: URLError(.timedOut).localizedDescription))
    #expect(classify(URLError(.networkConnectionLost)).ambiguous && classify(URLError(.networkConnectionLost)).round == .stopsRest(why: "offline"))
    for status in [500, 502, 503, 520, 524] { #expect(classify(BackendError.http(status, "x")).ambiguous && classify(BackendError.http(status, "x")).round == .stopsRest(why: "timeout")) }
    // Any other error before the headers.
    for error: Error in [BackendError.unavailable("x"), BackendError.invalidURL, AttachmentError.unreadable("a.png")] {
        #expect(classify(error).state == .notSent && classify(error).why == "error" && classify(error).round == .continues && !classify(error).ambiguous)
    }
    // Connection error after the headers.
    let cut = classify(StreamBreak(delivered: true, underlying: URLError(.networkConnectionLost)))
    #expect(cut.state == .incomplete && cut.round == .stopsRest(why: "offline"))
    // EOF without a terminal event, or the box's own failure.
    let eof = classify(StreamBreak(delivered: true, underlying: StreamBreak.EndOfStream()))
    #expect(eof.state == .incomplete && eof.round == .continues)
    #expect(TurnOutcome.classify(.endedWithoutTerminal).state == .incomplete && TurnOutcome.classify(.failedByAgent("x")).round == .continues)
    // Footers.
    #expect(TurnOutcome.footer(state: .notSent, why: "offline", ambiguous: false, empty: true) == "Not sent (offline)")
    #expect(TurnOutcome.footer(state: .notSent, why: "timeout", ambiguous: true, empty: true) == "Not confirmed (timeout) — the bot may have it")
    #expect(TurnOutcome.footer(state: .incomplete, why: nil, ambiguous: false, empty: false) == "Incomplete")
    #expect(TurnOutcome.footer(state: .stopped, why: nil, ambiguous: false, empty: true) == "Stopped" && TurnOutcome.footer(state: .stopped, why: nil, ambiguous: false, empty: false) == nil)
    #expect(TurnOutcome.footer(state: .finished, why: "later", ambiguous: false, empty: true) == "Delivered with a later message")
    #expect(TurnOutcome.footer(state: .finished, why: nil, ambiguous: false, empty: false) == nil && TurnOutcome.footer(state: nil, why: nil, ambiguous: false, empty: true) == nil)
}

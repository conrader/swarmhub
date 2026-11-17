import Foundation

/// What a turn has shown so far and what that means, whichever way it was learned: from the bridge's event stream or
/// from its polling routes. Both feed it the same things (saved rows, the reply so far, tool calls, the agent's
/// status), and it decides the same way for both: when the turn's reply is complete, what to show meanwhile, and
/// when an agent that saved nothing has gone quiet. Because it also remembers what it already reported, a turn can
/// move from the stream to polling in the middle and no step is shown twice.
struct HerdrTurnFollower: Sendable {
    enum Step: Sendable, Equatable { case status(HerdrTurnStatus), tool(HerdrClient.ToolCall, isNew: Bool), partial(String) }
    enum Verdict: Sendable, Equatable { case waiting, reply(String), failed(HerdrClient.Failure) }

    /// The newest saved row and tool call before the turn: its own are the ones after those.
    let after: Int, afterTool: UInt64
    var quietLimit: Duration = .seconds(45)
    /// After a reply with a steered message still unanswered: how long the agent may stay idle before the turn is over.
    var settle: Duration = .seconds(5)
    /// How long an agent that was starting when the turn began may sit idle before it shows work (`judgeAgent`).
    var startQuietLimit: Duration = .seconds(150)
    /// A new reply was just seen while a task is still unanswered: the agent's status is worth reading at once.
    var wantsAgentNow = false

    private var rows: [Int: HerdrClient.Item] = [:]
    private(set) var draft: HerdrEvent.Draft?
    /// seq → whether its end was reported too.
    private var reported: [UInt64: Bool] = [:]
    private var steps: [Step] = []
    private var lastStatus: HerdrTurnStatus?, lastDraft = ""
    /// The agent program's name for the status lines, and whether the turn started the agent (or found it starting):
    /// until the agent shows work, such a turn is "starting", any other "delivered" (`HerdrTurnStatus.of`).
    var program: String?, starting = false
    /// The agent has shown work in this turn: it said so, ran a tool, or wrote text.
    private var began = false
    private var repliesSeen = 0, settleSince: ContinuousClock.Instant?, quietSince: ContinuousClock.Instant?
    /// The agent's status as last heard; nil until it was.
    private var agentState: String?

    init(after: Int, afterTool: UInt64 = 0, quietLimit: Duration = .seconds(45), program: String? = nil, starting: Bool = false) {
        self.after = after; self.afterTool = afterTool; self.quietLimit = quietLimit; self.program = program; self.starting = starting
    }

    /// The newest saved row this turn has seen, to resume a stream from.
    var newestRow: Int { max(after, rows.keys.max() ?? 0) }

    // MARK: What was learned

    /// Saved rows, in any order and as often as they come: a row replaces the one with its id.
    mutating func take(rows new: [HerdrClient.Item]) { for row in new where row.id > after { rows[row.id] = row } }

    /// Tool calls: each is reported when first seen, and once more when it has ended.
    mutating func take(tools calls: [HerdrClient.ToolCall]) {
        for call in calls.sorted(by: { $0.seq < $1.seq }) where call.seq > afterTool && reported[call.seq] != true {
            if reported[call.seq] == nil { steps.append(.tool(call, isNew: true)) } else if call.finished { steps.append(.tool(call, isNew: false)) } else { continue }
            reported[call.seq] = call.finished; began = true
        }
    }

    /// The reply so far as the polling route gives it: the text alone, or nil when there is none.
    mutating func take(draftText text: String?) { draft = text.flatMap { $0.isEmpty ? nil : HerdrEvent.Draft(id: draft?.id ?? "", text: $0) } }

    /// The reply so far as the stream gives it: whole (`draft`), or nil when it is gone.
    mutating func take(draft whole: HerdrEvent.Draft?) { draft = whole }

    /// Text the reply so far gained. False when it does not fit what is held (another message, or another length):
    /// the reader must connect again to get it whole.
    mutating func append(draft id: String, offset: Int, text: String) -> Bool {
        guard let held = draft, held.id == id, held.text.utf8.count == offset else { return false }
        draft = HerdrEvent.Draft(id: id, text: held.text + text)
        return true
    }

    mutating func take(agent: HerdrClient.Agent) { agentState = agent.status?.state ?? "" }

    /// The steps to show that the last readings produced, oldest first.
    mutating func drain() -> [Step] { defer { steps = [] }; return steps }

    // MARK: What it means

    private var replies: [HerdrClient.Item] { rows.values.filter { $0.kind == "reply" }.sorted { $0.id < $1.id } }
    private var answered: String { replies.map(\.text).joined(separator: "\n\n") }

    /// The saved rows and the reply so far. A message steered into the turn is one more task: the agent may answer
    /// it within the same reply, or queue it and answer it right after, and then the turn's text is both replies.
    mutating func judgeSaved(now: ContinuousClock.Instant) -> Verdict {
        let replies = replies, tasks = rows.values.filter(\.reachedAgent).count, answered = answered
        // A message the bridge kept for an agent that was still starting, and then gave up: it was never typed.
        if replies.isEmpty, let lost = rows.values.first(where: \.wasNotSent) { return .failed(.notDelivered(lost.detail.flatMap { $0.isEmpty ? nil : $0 })) }
        if !replies.isEmpty {
            if replies.count >= max(tasks, 1) { return .reply(answered) }
            if replies.count != repliesSeen { repliesSeen = replies.count; settleSince = now; steps.append(.partial(answered)); wantsAgentNow = true }
            if let since = settleSince, now - since >= settle { return .reply(answered) }
        }
        if let text = draft?.text, !text.isEmpty, text != lastDraft { steps.append(.partial(answered.isEmpty ? text : answered + "\n\n" + text)); lastDraft = text; began = true }
        return .waiting
    }

    /// The agent's status as last heard: what to say the turn is waiting for (`HerdrTurnStatus`), and whether an
    /// agent that saved nothing has been quiet for too long.
    mutating func judgeAgent(now: ContinuousClock.Instant) -> Verdict {
        guard let state = agentState else { return .waiting }
        // The bridge still keeps the turn's message for an agent that is starting: whatever the program reports
        // meanwhile is its own start-up (Codex's counts as a turn), not work on the message.
        if rows.values.contains(where: { $0.kind == "task" && $0.state == "pending" }) {
            let status = HerdrTurnStatus.starting(program: program)
            if status != lastStatus { steps.append(.status(status)); lastStatus = status }
            quietSince = nil
            return .waiting
        }
        // Working again after a reply: the queued message is being answered, so keep waiting for it.
        if state == "working", settleSince != nil { settleSince = now }
        if state == "working" { began = true }
        let status = HerdrTurnStatus.of(agentState: state, program: program, began: began, starting: starting)
        if status != lastStatus { steps.append(.status(status)); lastStatus = status }
        // "done" or "idle" with nothing saved: the hook may still be writing; stop waiting once it cannot be.
        guard state == "done" || state == "idle" else { quietSince = nil; return .waiting }
        let since = quietSince ?? now
        quietSince = since
        // An agent program that has just started may report before it takes its first message (the message then
        // waits in its own input), so a turn that began with a starting agent is given longer.
        let limit = starting && !began ? max(quietLimit, startQuietLimit) : quietLimit
        return now - since >= limit ? .failed(.silent) : .waiting
    }

    /// The session is over: the turn's replies if its hook saved any as it closed, else the turn ended unanswered.
    func ended() throws -> String {
        guard !replies.isEmpty else { throw HerdrClient.Failure.ended }
        return answered
    }
}

extension HerdrClient {
    /// The turn on the bridge's event stream. Returns the reply, throws what the turn itself came to (`.ended`,
    /// `.silent`), and returns nil when the stream is no use: the bridge has no such route or no stream free, or it
    /// failed `streamAttempts` times in a row. The caller then polls, with `follower` as it stands. A stream that
    /// breaks after it delivered something is opened again from the newest row seen, so nothing is read twice.
    func streamedReply(to turn: Turn, follower: inout HerdrTurnFollower, emit: ([HerdrTurnFollower.Step]) -> Void,
                       live: @Sendable (LiveNote) -> Void) async throws -> String? {
        enum Input: Sendable { case event(HerdrEvent), tick, closed(Error?) }
        let clock = ContinuousClock(), agent = AgentRef(address: turn.address, createdMs: turn.createdMs)
        // `connections` bounds a stream that opens and breaks over and over: that is polling by another name.
        var failures = 0, connections = 0
        while failures < streamAttempts, connections < 24 {
            connections += 1
            try Task.checkCancellation()
            let resume = follower.newestRow
            let source = events(of: agent, after: resume > 0 ? resume : nil)
            // Events and a clock in one line: the settle and quiet limits have to pass even when nothing arrives.
            let (inputs, feed) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
            let reader = Task {
                do { for try await event in source { feed.yield(.event(event)) }; feed.yield(.closed(nil)) } catch { feed.yield(.closed(error)) }
            }
            let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: pollInterval); feed.yield(.tick) } }
            defer { reader.cancel(); ticker.cancel(); feed.finish() }
            var delivered = false, broke: Error?
            connection: for await input in inputs {
                if Task.isCancelled { reader.cancel(); ticker.cancel(); throw CancellationError() }
                switch input {
                case .tick: break
                case .closed(let error):
                    broke = error; break connection
                case .event(let event):
                    switch event {
                    case .snapshot(let snapshot):
                        delivered = true; failures = 0
                        live(.following(true))
                        follower.take(rows: snapshot.rows); follower.take(tools: snapshot.tools); follower.take(draft: snapshot.draft)
                        if let agent = snapshot.agent { follower.take(agent: agent) }
                        live(.helpers(snapshot.helpers))
                    case .history(let row): follower.take(rows: [row])
                    case .draft(let draft): follower.take(draft: draft)
                    case .draftAppend(let id, let offset, let text):
                        // Text that does not fit what is held: connect again and take the reply so far whole.
                        if !follower.append(draft: id, offset: offset, text: text) { break connection }
                    case .tool(let call): follower.take(tools: [call])
                    case .agent(let agent): follower.take(agent: agent)
                    case .helpers(let helpers): live(.helpers(helpers))
                    case .end:
                        // The server waited for the hook's last reply before it said so: the rows are final.
                        emit(follower.drain())
                        return try follower.ended()
                    case .heartbeat: break
                    }
                }
                let saved = follower.judgeSaved(now: clock.now), agentVerdict = follower.judgeAgent(now: clock.now)
                emit(follower.drain())
                if case .reply(let text) = saved { return text }
                if case .failed(let failure) = saved { throw failure }
                if case .failed(let failure) = agentVerdict { throw failure }
            }
            reader.cancel(); ticker.cancel()
            try Task.checkCancellation()
            // No route (an older bridge), no stream free, or not let in: the polling routes say the same more slowly.
            if let failure = broke as? Failure, !delivered { if case .http = failure { return nil }; if failure == .unauthorized || failure == .refusedHost { return nil } }
            failures += 1
            if failures < streamAttempts { try await Task.sleep(for: .milliseconds(300 * failures)) }
        }
        return nil
    }
}

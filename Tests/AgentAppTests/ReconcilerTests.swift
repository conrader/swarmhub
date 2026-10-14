import Foundation
import Testing
@testable import AgentApp

// P16 Part 1: the pure engine. Made-up text only.

typealias LRow = HistoryReconciler.LocalRow
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func lrow(_ role: MessageRole, _ text: String, state: TurnState? = nil, author: UUID? = nil, for trigger: UUID? = nil, at seconds: Double = 0, steer: Bool = false, streaming: Bool = false) -> LRow {
    LRow(role: role, text: text, isTextTurn: !steer, authorID: author, state: state, metadata: trigger.map { ["for": $0.uuidString] } ?? [:], createdAt: t0.addingTimeInterval(seconds), isStreaming: streaming)
}

private let serverIDs = LockedValue(1)
func srow(_ role: String, _ text: String, finish: String? = nil, at seconds: Double? = nil, id: Int? = nil) -> BackendMessage {
    let next = serverIDs.current + 1; _ = serverIDs.swap(next)
    return BackendMessage(id: id ?? next, role: role, content: text, createdAt: seconds.map { t0.addingTimeInterval($0) }, finishReason: finish)
}

/// Applies a plan the way `AppStore.apply` does (edits to unchanged rows, insertions after anchors).
func applied(_ plan: HistoryReconciler.Plan, to local: [LRow]) -> [LRow] {
    var rows = local
    for edit in plan.edits {
        guard let index = rows.firstIndex(where: { $0.id == edit.rowID }) else { continue }
        if let content = edit.content { rows[index].text = content }
        if let state = edit.state { rows[index].state = state }
        for (key, value) in edit.metadata { rows[index].metadata[key] = value }
    }
    for addition in plan.additions {
        let new = addition.rows.map { LRow(role: $0.role, text: $0.content, authorID: $0.authorID, state: $0.state, metadata: $0.metadata, createdAt: $0.createdAt) }
        if let after = addition.after, let index = rows.firstIndex(where: { $0.id == after }) { rows.insert(contentsOf: new, at: index + 1) } else { rows += new }
    }
    return rows
}

private func chatPlan(_ local: [LRow], _ server: [BackendMessage], active: Set<UUID> = [], covers: Date? = nil, now: Date = t0) -> HistoryReconciler.Plan {
    HistoryReconciler.plan(.init(local: local, server: server, mode: .chat(additions: true), now: now, coversFrom: covers, activeRuns: active))
}

@MainActor @Test func mergeHistoryCasesGiveTheSameRowsThroughTheEngine() {
    let local = [lrow(.user, "pre-Hermes"), lrow(.system, "Stop requested from Hermes."), lrow(.user, "new turn"), lrow(.assistant, "reply")]
    let server = [srow("user", "new turn"), srow("assistant", "reply"), srow("user", "newer"), srow("assistant", "answer")]
    let result = applied(chatPlan(local, server), to: local)
    let merged = AppStore.mergeHermesHistory(local: local.map { ChatMessage(role: $0.role, content: $0.text) }, server: server)!
    #expect(result.map(\.text) == merged.map(\.content) && result.prefix(4).map(\.id) == local.map(\.id))
    #expect(chatPlan(local, [srow("user", "unrelated")]).diverged)
    let question = [lrow(.user, "question")]
    let multimodal = applied(chatPlan(question, [srow("user", "question"), srow("assistant", "text\n[Image: https://example.test/a.png]")]), to: question)
    #expect(multimodal.count == 2 && multimodal[0].id == question[0].id && multimodal[1].role == .assistant)
}

@Test func equalSettlesOnlyWhenTheBoxAttestsAndNilStaysNil() {
    let reply = lrow(.assistant, "done text", state: .incomplete)
    let plan = chatPlan([lrow(.user, "q"), reply], [srow("user", "q"), srow("assistant", "done text", finish: "stop")])
    #expect(plan.edits.first?.state == .finished && plan.counts.settled == 1)
    #expect(chatPlan([lrow(.user, "q"), lrow(.assistant, "done text")], [srow("user", "q"), srow("assistant", "done text", finish: "stop")]).isEmpty, "a nil row that is equal gets no stamp")
}

@Test func theIncidentReplyIsExtendedFrom100To293() {
    let first = syntheticParagraph(98, seed: 3), second = syntheticParagraph(193, seed: 4)
    let local = first + "\n\n"
    #expect(local.count == 100 && (first + "\n\n" + second).count == 293)
    let reply = lrow(.assistant, local)
    let plan = chatPlan([lrow(.user, "q"), reply], [srow("user", "q"), srow("assistant", first + "\n\n" + second, finish: "stop")])
    let edit = try! #require(plan.edits.first)
    #expect(edit.content == first + "\n\n" + second && edit.content!.hasPrefix(local) && edit.state == .finished)
    #expect(plan.counts.extended == 1 && plan.counts.extendedChars == 193 && edit.metadata["restored"] == "extended")
}

@Test func extendingHandlesLeadingBlankLinesAndSegmentJoins() {
    #expect(HistoryReconciler.extend("\n\nalpha beta", with: "alpha beta gamma") == "\n\nalpha beta gamma")
    #expect(HistoryReconciler.extend("alpha ", with: "alpha\nbeta") == "alpha beta")
    let plan = chatPlan([lrow(.user, "q"), lrow(.assistant, "first part", state: .incomplete)],
                        [srow("user", "q"), srow("assistant", "first part"), srow("assistant", "second part", finish: "stop")])
    #expect(plan.edits.first?.content == "first part\n\nsecond part")
}

@Test func serverPrefixAndConflictLeaveTheRowAndAreCounted() {
    let shorter = chatPlan([lrow(.user, "q"), lrow(.assistant, "longer local text", state: .incomplete)], [srow("user", "q"), srow("assistant", "longer local", finish: "stop")])
    #expect(shorter.edits.isEmpty && shorter.counts.serverPrefix == 1)
    let conflict = chatPlan([lrow(.user, "q"), lrow(.assistant, "one thing", state: .incomplete)], [srow("user", "q"), srow("assistant", "another", finish: "stop")])
    #expect(conflict.edits.isEmpty && conflict.counts.conflicts == 1)
}

@Test func emptyAndNotSentRowsAreFilledFromTheBox() {
    let empty = chatPlan([lrow(.user, "q"), lrow(.assistant, "", state: .incomplete)], [srow("user", "q"), srow("assistant", "full answer", finish: "stop")])
    #expect(empty.edits.first?.content == "full answer" && empty.counts.filled == 1)
    let notSent = chatPlan([lrow(.user, "q"), lrow(.assistant, "", state: .notSent)], [srow("user", "q"), srow("assistant", "the box had it", finish: "stop")])
    #expect(notSent.edits.first?.content == "the box had it" && notSent.edits.first?.state == .finished)
    let pending = chatPlan([lrow(.user, "q"), lrow(.assistant, "", state: .notSent)], [srow("user", "q")])
    #expect(pending.edits.first?.state == .incomplete && pending.edits.first?.content == nil, "the box has the user turn, no reply yet")
}

@Test func additionsAtTheTailAndMidTranscriptAreCapped() {
    var local = [lrow(.user, "anchor question", at: 100), lrow(.assistant, "anchor answer", state: .finished, at: 101)]
    local += [lrow(.user, "local only later", at: 1_000)]
    var server = [srow("user", "anchor question", at: 100), srow("assistant", "anchor answer", finish: "stop", at: 101)]
    for index in 0..<12 { server += [srow("user", "mid \(syntheticParagraph(12, seed: 100 + index))", at: 200 + Double(index)), srow("assistant", syntheticParagraph(40, seed: 200 + index), finish: "stop", at: 201 + Double(index))] }
    server += [srow("user", "tail \(syntheticParagraph(12, seed: 99))", at: 2_000), srow("assistant", syntheticParagraph(30, seed: 98), finish: "stop", at: 2_001)]
    let plan = chatPlan(local, server)
    #expect(plan.counts.added == 11 && plan.counts.capped == 2)
    #expect(plan.additions.filter { $0.after != nil }.flatMap(\.rows).count == 20 && plan.additions.last?.after == nil, "ten mid turns (user and reply), in box order")
    let mid = plan.additions.first { $0.after != nil }!.rows.filter { $0.role == .user }.map(\.content)
    #expect(mid == (0..<10).map { "mid \(syntheticParagraph(12, seed: 100 + $0))" })
    let result = applied(plan, to: local)
    #expect(result.filter { local.map(\.id).contains($0.id) }.map(\.id) == local.map(\.id), "no local row moves")
}

@Test func oldTurnsAreIgnoredAndUnpairedLocalTurnsKept() {
    let local = [lrow(.user, "kept local"), lrow(.assistant, "kept reply", state: .incomplete), lrow(.user, "shared"), lrow(.assistant, "same")]
    let server = [srow("user", "older box turn"), srow("assistant", "older reply"), srow("user", "shared"), srow("assistant", "same")]
    let plan = chatPlan(local, server)
    #expect(plan.counts.ignoredOld == 1 && plan.additions.isEmpty && plan.edits.isEmpty)
}

@Test func duplicatesAreNeverAdded() {
    let twice = chatPlan([lrow(.user, "hi"), lrow(.assistant, "ok")], [srow("user", "hi"), srow("assistant", "ok"), srow("user", "hi"), srow("assistant", "ok")])
    #expect(twice.additions.isEmpty, "the box's other \"ok\" turn is never added")
    let near = chatPlan([lrow(.user, "hi"), lrow(.assistant, "ok")], [srow("user", "hi"), srow("assistant", "ok"), srow("user", "hello again"), srow("assistant", "okay")])
    #expect(near.additions.isEmpty && near.counts.ambiguous == 1, "\"ok\" vs \"okay\" is prefix-related")
    let known = lrow(.assistant, "x", metadata: ["box": "7"])
    #expect(chatPlan([lrow(.user, "a"), known], [srow("user", "a", id: 6), srow("assistant", "x", id: 7), srow("user", "b", id: 8), srow("assistant", "y", id: 9)]).counts.added == 1)
}

@Test func aResendCannotTakeTheBoxsTurnAndRetypesStayApart() {
    // A failed "hi" then a resent "hi": the reply with text pairs first.
    let replied = lrow(.assistant, "hello there", state: .finished), resent = lrow(.assistant, "", state: .notSent)
    let plan = chatPlan([lrow(.user, "hi"), replied, lrow(.user, "hi"), resent], [srow("user", "hi"), srow("assistant", "hello there", finish: "stop")])
    #expect(plan.edits.isEmpty && plan.additions.isEmpty)
    // A failed message then a retyped one.
    let typo = chatPlan([lrow(.user, "hello wrold"), lrow(.assistant, "", state: .notSent), lrow(.user, "hello world"), lrow(.assistant, "answer", state: .finished)],
                        [srow("user", "hello world"), srow("assistant", "answer", finish: "stop")])
    #expect(typo.edits.isEmpty && typo.additions.isEmpty)
}

@Test func aRetryThatLandedOutOfOrderStillPairs() {
    let a = lrow(.assistant, "", state: .notSent)
    let plan = chatPlan([lrow(.user, "first"), a, lrow(.user, "second"), lrow(.assistant, "second reply", state: .finished)],
                        [srow("user", "second"), srow("assistant", "second reply", finish: "stop"), srow("user", "first"), srow("assistant", "first reply", finish: "stop")])
    #expect(plan.edits.first { $0.rowID == a.id }?.content == "first reply" && plan.additions.isEmpty)
}

@Test func steerRowsAndImagesAreIgnoredAndFinishedRowsConsumeTheirPair() {
    let local = [lrow(.user, "look at this"), lrow(.user, "faster please", steer: true), lrow(.assistant, "short", state: .finished)]
    let server = [srow("user", "[Image: inline]\nlook at this"), srow("assistant", "short and more", finish: "stop")]
    let plan = chatPlan(local, server)
    #expect(plan.edits.isEmpty && plan.additions.isEmpty && plan.counts.paired == 1)
    let stopped = chatPlan([lrow(.user, "q"), lrow(.assistant, "par", state: .stopped)], [srow("user", "q"), srow("assistant", "partial", finish: "stop")])
    #expect(stopped.isEmpty)
}

@Test func attestationNeedsANormalFinishAndRunStatusOnlyVetoes() {
    func plan(_ finish: String?, active: Bool = false) -> HistoryReconciler.Plan {
        let reply = lrow(.assistant, "same text", state: .incomplete)
        return chatPlan([lrow(.user, "q"), reply], [srow("user", "q"), srow("assistant", "same text", finish: finish)], active: active ? [reply.id] : [])
    }
    #expect(plan("stop").edits.first?.state == .finished && plan("length").edits.first?.state == .finished && plan("end_turn").edits.first?.state == .finished)
    for reason in [nil, "tool_calls", "incomplete"] as [String?] { #expect(plan(reason).edits.first?.metadata["end"] == "none" && plan(reason).edits.first?.state == .incomplete) }
    for reason in ["error", "agent_error", "content_filter"] { #expect(plan(reason).edits.first?.metadata["end"] == "error") }
    let active = plan("stop", active: true)
    #expect(active.edits.isEmpty && !active.keepPolling.isEmpty, "an active run never attests")
}

@Test func anOldEmptyPlaceholderTheBoxNeverGotBecomesNotSent() {
    let placeholder = lrow(.assistant, "", state: .incomplete, at: 0)
    let local = [lrow(.user, "shared"), lrow(.assistant, "same"), lrow(.user, "lost", at: 0), placeholder]
    let server = [srow("user", "shared"), srow("assistant", "same")]
    #expect(chatPlan(local, server, now: t0.addingTimeInterval(200)).edits.first?.state == .notSent)
    #expect(chatPlan(local, server, now: t0.addingTimeInterval(60)).edits.isEmpty, "younger than 120 s")
    #expect(chatPlan(local, server, covers: t0.addingTimeInterval(10), now: t0.addingTimeInterval(200)).edits.isEmpty, "the read did not reach back")
}

// MARK: Groups

private let members = [GroupRouting.Member(id: UUID(), name: "Alpha"), GroupRouting.Member(id: UUID(), name: "Beta")]

private func blob(for member: GroupRouting.Member, _ messages: [ChatMessage], current: UUID? = nil, limit: Int = GroupRouting.contextLimit) -> String {
    GroupRouting.context(for: member, groupName: "Konrad, Alpha, Beta", members: members, messages: messages, current: current, limit: limit)
}

@MainActor private func groupPlan(_ local: [ChatMessage], _ server: [BackendMessage], member: GroupRouting.Member = members[0]) -> HistoryReconciler.Plan {
    HistoryReconciler.plan(.init(local: local.map { LRow($0) }, server: server, mode: .group(member: member.id, names: members.map(\.name)), now: t0))
}

@Test func parseContextReadsWholeEntriesBuiltByContext() {
    let messages = [ChatMessage(role: .user, content: "line one\nline two"), ChatMessage(role: .assistant, content: "Beta speaks", authorID: members[1].id), ChatMessage(role: .user, content: "ok")]
    let entries = try! #require(GroupRouting.parseContext(blob(for: members[0], messages), names: members.map(\.name)))
    #expect(entries == [.init(author: "Konrad", text: "line one\nline two"), .init(author: "Beta", text: "Beta speaks"), .init(author: "Konrad", text: "ok")])
    #expect(GroupRouting.parseContext("plain user text", names: []) == nil)
}

@MainActor @Test func groupTurnsPairByWholeEntriesNeverSubstrings() {
    let trigger = ChatMessage(role: .user, content: "ok")
    let reply = ChatMessage(role: .assistant, content: "", authorID: members[0].id, turnState: .incomplete); reply.metadata["for"] = trigger.id.uuidString
    let other = ChatMessage(role: .user, content: "ok then, more")
    let serverBlob = blob(for: members[0], [other])
    #expect(groupPlan([trigger, reply], [srow("user", serverBlob), srow("assistant", "not this one", finish: "stop")]).edits.isEmpty, "\"ok\" is only a substring")
    let real = blob(for: members[0], [trigger], current: trigger.id)
    #expect(groupPlan([trigger, reply], [srow("user", real), srow("assistant", "for ok", finish: "stop")]).edits.first?.content == "for ok")
}

@MainActor @Test func emptyAndCapDroppedTriggersPairByReplyOnly() {
    let image = ChatMessage(role: .user, content: "")
    let long = syntheticParagraph(60, seed: 7)
    let reply = ChatMessage(role: .assistant, content: String(long.prefix(30)), authorID: members[0].id, turnState: .incomplete)
    let plan = groupPlan([image, reply], [srow("user", blob(for: members[0], [image], current: image.id)), srow("assistant", long, finish: "stop")])
    #expect(plan.edits.first?.content == long && plan.additions.isEmpty)
    // The cap cut the trigger: no duplicate reply is added.
    let huge = ChatMessage(role: .user, content: String(repeating: "word ", count: 3_000))
    let answer = ChatMessage(role: .assistant, content: long, authorID: members[0].id, turnState: .finished)
    let capped = blob(for: members[0], [ChatMessage(role: .user, content: "filler"), huge, ChatMessage(role: .assistant, content: "Beta was here", authorID: members[1].id)], limit: 400)
    #expect(capped.contains(GroupRouting.omittedMarker))
    let second = groupPlan([huge, answer], [srow("user", capped), srow("assistant", long, finish: "stop")])
    #expect(second.additions.isEmpty)
}

@MainActor @Test func aLaterTurnSettlesAMemberRowItCarried() {
    let first = ChatMessage(role: .user, content: "first ask"), second = ChatMessage(role: .user, content: "second ask")
    let skipped = ChatMessage(role: .assistant, content: "", authorID: members[0].id, turnState: .notSent); skipped.metadata["for"] = first.id.uuidString
    let answered = ChatMessage(role: .assistant, content: "both answered", authorID: members[0].id, turnState: .finished); answered.metadata["for"] = second.id.uuidString
    let server = [srow("user", blob(for: members[0], [first, skipped, second], current: second.id)), srow("assistant", "both answered", finish: "stop")]
    let plan = groupPlan([first, skipped, second, answered], server)
    #expect(plan.edits.first { $0.rowID == skipped.id }?.state == .finished && plan.edits.first?.metadata["why"] == "later")
}

// MARK: Invariants over generated cases

@Test func generatedCasesKeepEveryInvariant() {
    var seed: UInt64 = 0x5eed
    func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % bound }
    for _ in 0..<300 {
        var local: [LRow] = [], server: [BackendMessage] = []
        for turn in 0..<(1 + next(6)) {
            let user = "ask \(turn) " + syntheticParagraph(8 + next(10), seed: next(10_000)), full = syntheticParagraph(20 + next(120), seed: next(10_000))
            let onBox = next(5) != 0, onMac = next(5) != 0
            if onBox { server += [srow("user", user), srow("assistant", full, finish: ["stop", nil, "length", "error"][next(4)])] }
            guard onMac else { continue }
            let states: [TurnState?] = [.finished, nil, .incomplete, .notSent, .stopped]
            let state = states[next(states.count)]
            let text = state == .notSent ? "" : state == .finished ? full : String(full.prefix(next(full.count + 1)))
            local += [lrow(.user, user), lrow(.assistant, text, state: state, streaming: next(10) == 0)]
        }
        let plan = chatPlan(local, server)
        let result = applied(plan, to: local)
        #expect(result.filter { row in local.contains { $0.id == row.id } }.map(\.id) == local.map(\.id), "no row deleted or reordered")
        for old in local {
            let new = result.first { $0.id == old.id }!
            #expect(new.text.hasPrefix(old.text), "an extended reply keeps its old text")
            if old.isStreaming || old.state == .stopped || old.state == .finished { #expect(new == old, "streaming, stopped and finished rows are never touched") }
        }
        #expect(chatPlan(result, server).isEmpty, "a second pass over the same rows changes nothing")
    }
}

func lrow(_ role: MessageRole, _ text: String, metadata: [String: String]) -> LRow { LRow(role: role, text: text, metadata: metadata) }

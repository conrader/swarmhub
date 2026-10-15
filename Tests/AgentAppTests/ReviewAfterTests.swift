import Foundation
import Testing
@testable import AgentApp

/// P37 D4: review-after lines with a mock reviewer: the card, the verdict, "Send notes to <bot>", the automatic option.
@MainActor private func reviewSetup(answer: TestBackend.StreamMode, auto: Bool = false, timeout: Duration = waitCeiling) -> (AppStore, Bot, Bot, ChatMessage, TestBackend, TestBackend) {
    let coder = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder"), jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "jarvis")
    let ownerBackend = TestBackend(transport: .nativeSessions), reviewerBackend = TestBackend(transport: .nativeSessions, streamMode: answer)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == jarvis.id ? reviewerBackend : ownerBackend },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.reviewTimeout = timeout
    store.bots = [coder, jarvis]
    coder.reviewAfter = [ReviewAfterRule(trigger: .codingJob, reviewerID: jarvis.id, autoSendNotes: auto)]
    let reply = ChatMessage(role: .assistant, content: "Fixed the export.\ncode-job: claude done · waited 0s · ran 41s · peak 210 MB\n 3 files changed, 12 insertions(+), 4 deletions(-)", turnState: .finished)
    var activity = ToolActivity(), t = Date.now
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "code-job --bot coder --order claude", callID: "1"), at: t)
    activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "1"), at: t.addingTimeInterval(41)); activity.finish(at: t.addingTimeInterval(42))
    reply.activity = activity
    coder.messages = [ChatMessage(role: .user, content: "fix the slow export"), reply]
    return (store, coder, jarvis, reply, ownerBackend, reviewerBackend)
}

@Test func reviewSummaryAndVerdictFormat() {
    let reply = ChatMessage(role: .assistant, content: "Done.\ncode-job: codex done · ran 9s\n2 files changed, 5 insertions(+)")
    var activity = ToolActivity()
    activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "src/a.swift", callID: "1"), at: .now)
    activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "bot-msg --to infra", callID: "2", command: "bot-msg --to infra -- hi"), at: .now)
    reply.activity = activity
    let summary = ReviewSummary(reply: reply)
    #expect(summary.codeJobLine == "code-job: codex done · ran 9s" && summary.diffStat == "2 files changed, 5 insertions(+)")
    #expect(summary.steps == ["read_file — src/a.swift", "terminal — → infra"])
    let prompt = summary.prompt(owner: "Coder", why: "finished a coding job", boundary: "B")
    #expect(prompt.contains("---BEGIN B---") && prompt.contains("Steps:\n1. read_file") && prompt.contains("Code job: code-job: codex") && prompt.contains("Diff stat: 2 files"))
    #expect(prompt.contains("VERDICT: ok or VERDICT: changes"))
    let steps = reply.activity!.steps
    #expect(summary.matches(ReviewAfterRule(trigger: .botMessage, botMessageTo: "infra", reviewerID: UUID()), steps: steps, toName: { _ in nil }))
    #expect(!summary.matches(ReviewAfterRule(trigger: .botMessage, botMessageTo: "coder", reviewerID: UUID()), steps: steps, toName: { _ in nil }))
    #expect(summary.matches(ReviewAfterRule(trigger: .changedFiles, reviewerID: UUID()), steps: steps, toName: { _ in nil }))

    #expect(ReviewVerdict.parse("VERDICT: ok") == (.ok, ""))
    #expect(ReviewVerdict.parse("  verdict: CHANGES\nRename foo.\nAdd a test.") == (.changes, "Rename foo.\nAdd a test."))
    #expect(ReviewVerdict.parse("Looks fine to me").verdict == .text && ReviewVerdict.parse("VERDICT: maybe\nx").verdict == .text)
}

@Test @MainActor func reviewCardGetsTheVerdictAndNotesGoToTheBotInOneClick() async throws {
    let (store, coder, jarvis, reply, ownerBackend, reviewerBackend) = reviewSetup(answer: .response("VERDICT: changes\nAdd a test for the empty CSV."))
    let card = try #require(store.startReviewIfNeeded(reply, from: coder, in: coder))
    #expect(coder.messages.firstIndex { $0.id == card.id } == 2, "the card sits under the reply")
    #expect(card.presentation == .review && card.metadata[ReviewKey.reviewer] == jarvis.id.uuidString)
    try await waitUntil { card.metadata[ReviewKey.state] != "pending" }
    #expect(card.metadata[ReviewKey.state] == "changes" && card.metadata[ReviewKey.notes] == "Add a test for the empty CSV." && card.content == "Jarvis: changes requested")
    #expect(await reviewerBackend.recordedCalls().contains("create:swarmhub-review-coder"), "the reviewer's own session, Review: Coder")
    #expect(coder.approvalAudit.last?.actionKind == "review" && coder.approvalAudit.last?.decidedBy == "reviewer:\(jarvis.id.uuidString)")
    #expect(store.reviewCards(of: coder).map(\.id) == [card.id])
    #expect(!(await ownerBackend.recordedCalls()).contains("send"), "not sent until asked")

    #expect(store.canSendReviewNotes(card) && store.sendReviewNotes(card))
    try await ownerBackend.calls.wait { $0.contains("send") }
    #expect(coder.messages.contains { $0.role == .user && $0.content == "Review notes from Jarvis:\nAdd a test for the empty CSV." })
    #expect(card.metadata[ReviewKey.sent] == "1" && !store.canSendReviewNotes(card), "one click, once")
    try await waitUntil { !store.anyTurnRunning }
}

@Test @MainActor func automaticOptionForwardsChangesRequested() async throws {
    let (store, coder, _, reply, ownerBackend, _) = reviewSetup(answer: .response("VERDICT: changes\nHandle the timeout."), auto: true)
    let card = try #require(store.startReviewIfNeeded(reply, from: coder, in: coder))
    try await ownerBackend.calls.wait { $0.contains("send") }
    #expect(card.metadata[ReviewKey.sent] == "1" && coder.messages.contains { $0.content == "Review notes from Jarvis:\nHandle the timeout." })
    try await waitUntil { !store.anyTurnRunning }
}

@Test @MainActor func looksGoodUnparsedAndNoMatchCases() async throws {
    let (store, coder, jarvis, reply, ownerBackend, _) = reviewSetup(answer: .response("VERDICT: ok"), auto: true)
    let ok = try #require(store.startReviewIfNeeded(reply, from: coder, in: coder))
    try await waitUntil { ok.metadata[ReviewKey.state] == "ok" }
    let ownerCalls = await ownerBackend.recordedCalls()
    #expect(!store.canSendReviewNotes(ok) && ok.content == "Jarvis: looks good" && !ownerCalls.contains("send"), "nothing to forward")

    let (store2, coder2, _, reply2, _, _) = reviewSetup(answer: .response("I think it's mostly fine but rename x."))
    let text = try #require(store2.startReviewIfNeeded(reply2, from: coder2, in: coder2))
    try await waitUntil { text.metadata[ReviewKey.state] == "text" }
    #expect(text.metadata[ReviewKey.notes] == "I think it's mostly fine but rename x." && store2.canSendReviewNotes(text), "unparsed answers are shown as text")

    // No steps → no coding job → no review; a reviewer never reviews itself; a global line names its bot.
    let plain = ChatMessage(role: .assistant, content: "Hi", turnState: .finished)
    #expect(store.startReviewIfNeeded(plain, from: coder, in: coder) == nil)
    coder.reviewAfter = [ReviewAfterRule(trigger: .anySteps, reviewerID: coder.id)]
    #expect(store.reviewRule(for: reply, from: coder) == nil)
    store.globalReviewAfter = [ReviewAfterRule(trigger: .anySteps, reviewerID: jarvis.id, subjectBotID: jarvis.id)]
    #expect(store.reviewRule(for: reply, from: coder) == nil, "the global line is for Jarvis's replies only")
    store.globalReviewAfter[0].subjectBotID = nil
    #expect(store.reviewRule(for: reply, from: coder)?.reviewer.id == jarvis.id, "bot lines first, then global")
}

@Test @MainActor func reviewsNeverBlockAndTimeOutToNoReview() async throws {
    let (store, coder, _, reply, _, reviewerBackend) = reviewSetup(answer: .hanging, timeout: .milliseconds(30))
    let card = try #require(store.startReviewIfNeeded(reply, from: coder, in: coder))
    #expect(card.metadata[ReviewKey.state] == "pending" && reply.turnState == .finished, "the reply is already done; the card waits on its own")
    try await waitUntil { card.metadata[ReviewKey.state] == "failed" }
    #expect(card.metadata[ReviewKey.notes]?.hasPrefix("No review:") == true)
    try await reviewerBackend.calls.wait { $0.contains("post") }
}

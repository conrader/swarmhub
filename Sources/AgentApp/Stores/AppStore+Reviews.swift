import Foundation

/// P37 D4: "Review after" lines. When a bot's reply finishes and a line matches (the bot's own lines first, then the
/// SwarmHub-wide ones), SwarmHub sends the reviewer a summary of the reply in the reviewer's session "Review: <bot>"
/// (`swarmhub-review-<bot>`, through the reviewer's own session API: the app has no way to make a bot send a message
/// itself) and puts a review card under the reply. The card fills in when the verdict comes back; nothing waits on it.
extension AppStore {
    static func reviewSessionID(owner profile: String) -> String { "swarmhub-review-" + profile }

    /// The first review-after line for this reply whose reviewer exists and is not the bot itself.
    func reviewRule(for reply: ChatMessage, from bot: Bot) -> (rule: ReviewAfterRule, reviewer: Bot)? {
        let summary = ReviewSummary(reply: reply), steps = reply.activity?.steps ?? []
        let lines = bot.reviewAfter + globalReviewAfter.filter { $0.subjectBotID == nil || $0.subjectBotID == bot.id }
        for rule in lines where summary.matches(rule, steps: steps, toName: { [weak self] in self?.bot(forProfile: $0)?.name }) {
            guard let id = rule.reviewerID, id != bot.id, let reviewer = bots.first(where: { $0.id == id }) else { continue }
            return (rule, reviewer)
        }
        return nil
    }

    /// Called when a 1:1 or thread reply finished. Returns the card, or nil when no line matched.
    @discardableResult func startReviewIfNeeded(_ reply: ChatMessage, from bot: Bot, in conversation: any Conversation) -> ChatMessage? {
        guard reply.role == .assistant, !bot.isReadOnlyArchive, let (rule, reviewer) = reviewRule(for: reply, from: bot) else { return nil }
        let summary = ReviewSummary(reply: reply)
        let why = rule.trigger == .botMessage && !(rule.botMessageTo ?? "").isEmpty ? "sent a bot message to \(rule.botMessageTo!)" : "finished \(rule.trigger.title)"
        let card = ChatMessage(role: .system, content: "\(reviewer.name) is reviewing this reply…", createdAt: now(), presentation: .review,
                               metadata: [ReviewKey.reviewer: reviewer.id.uuidString, ReviewKey.state: "pending", ReviewKey.reply: reply.id.uuidString,
                                          ReviewKey.rule: rule.id.uuidString, ReviewKey.why: why])
        let index = conversation.messages.firstIndex { $0.id == reply.id }.map { $0 + 1 } ?? conversation.messages.endIndex
        conversation.messages.insert(card, at: index); objectWillChange.send(); save()
        let prompt = summary.prompt(owner: bot.name, why: why, boundary: "SWARMHUB_REVIEW_\(UUID().uuidString)")
        let sessionID = sessionNamespace + Self.reviewSessionID(owner: profile(of: bot))
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let answer = try await reviewerAnswer(reviewer: reviewer, sessionID: sessionID, title: "Review: \(bot.name)", prompt: prompt, timeout: reviewTimeout) else {
                    finishReview(card, state: "failed", notes: "\(reviewer.name) asked for an approval during the review; it was declined and the review stopped.", bot: bot, auto: false); return
                }
                let (verdict, notes) = ReviewVerdict.parse(answer)
                finishReview(card, state: verdict.rawValue, notes: notes, bot: bot, auto: rule.autoSendNotes && verdict == .changes)
            } catch {
                finishReview(card, state: "failed", notes: "No review: \(error.localizedDescription)", bot: bot, auto: false)
            }
        }
        return card
    }

    private func finishReview(_ card: ChatMessage, state: String, notes: String, bot: Bot, auto: Bool) {
        let reviewer = card.metadata[ReviewKey.reviewer].flatMap(UUID.init(uuidString:)).flatMap { id in bots.first { $0.id == id } }
        card.metadata[ReviewKey.state] = state; card.metadata[ReviewKey.notes] = notes
        let name = reviewer?.name ?? "Reviewer"
        card.content = switch state { case "ok": "\(name): looks good"; case "changes": "\(name): changes requested"; case "text": "\(name) reviewed this reply"; default: "\(name): no review" }
        bot.approvalAudit.append(.init(approvalID: card.id, actionKind: "review", outcome: state == "ok" ? .approved : state == "changes" ? .denied : .asked,
                                       decidedBy: reviewer.map { "reviewer:\($0.id.uuidString)" } ?? "system", reason: card.content, rule: card.metadata[ReviewKey.why]))
        if bot.approvalAudit.count > 500 { bot.approvalAudit.removeFirst(bot.approvalAudit.count - 500) }
        objectWillChange.send(); save()
        if auto { sendReviewNotes(card) }
    }

    /// The reviewer's notes, as the message that goes to the reviewed bot.
    func reviewNotesText(_ card: ChatMessage) -> String? {
        guard let notes = card.metadata[ReviewKey.notes]?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty else { return nil }
        let name = card.metadata[ReviewKey.reviewer].flatMap(UUID.init(uuidString:)).flatMap { id in bots.first { $0.id == id } }?.name ?? "Reviewer"
        return "Review notes from \(name):\n\(notes)"
    }

    func canSendReviewNotes(_ card: ChatMessage) -> Bool {
        card.presentation == .review && card.metadata[ReviewKey.sent] == nil && ["changes", "text"].contains(card.metadata[ReviewKey.state] ?? "") && reviewNotesText(card) != nil
    }

    /// "Send notes to <bot>": the notes go out as the next message in the reply's chat (at once when nothing runs, else
    /// when the running turn ends).
    @discardableResult func sendReviewNotes(_ card: ChatMessage) -> Bool {
        guard canSendReviewNotes(card), let text = reviewNotesText(card), let conversation = conversation(containing: card.id) else { return false }
        card.metadata[ReviewKey.sent] = "1"
        turns.nextMessages.append(QueuedNextMessage(conversation: conversation, bubble: ChatMessage(role: .user, content: text)))
        objectWillChange.send(); save()
        sendQueuedNextMessage()
        return true
    }

    /// Review cards of `bot`'s replies, newest first (the Activity tab).
    func reviewCards(of bot: Bot) -> [ChatMessage] {
        (bot.messages + bot.threads.flatMap(\.messages)).filter { $0.presentation == .review }.sorted { $0.createdAt > $1.createdAt }
    }
}

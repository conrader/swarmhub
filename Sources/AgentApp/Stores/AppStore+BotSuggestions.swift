import AppKit
import Foundation

/// recs1 state in memory: the ledger read from `UserDefaults` once, the prefilled routine editor waiting to open in a bot's
/// chat, and the bots being checked right now.
final class BotSuggestionBook {
    var ledger: BotSuggestionLedger?
    var editor: RoutineDraft?
    var evaluating: Set<UUID> = []
}

/// recs1 (Konrad, 2026-10-23): a recommendation is a normal message from the bot in its own chat, with suggested replies.
/// When an ask repeats (`RepeatedAskDetector`) and no routine covers it, the bot asks whether to run it on a schedule.
/// The answer, a chip or anything typed, goes to the bot as a normal message with the question as its lead, and the bot
/// makes the routine with its own cron tool; when no routine that does it can be read afterwards, the routine editor opens
/// prefilled with what the conversation settled on.
extension AppStore {
    static let suggestionsEnabledKey = "suggestions.enabled", suggestionLedgerKey = "suggestions.ledger"
    /// A typed message counts as the answer only this soon after the question (or the last answer to it); later it is just
    /// the next message. A chip on the question counts however late: the chips show until something answers it.
    static let suggestionAnswerWindow: TimeInterval = 12 * 3600

    /// Settings → Advanced → Chats → Suggestions (on by default).
    var suggestionsEnabled: Bool {
        get { defaults.object(forKey: Self.suggestionsEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.suggestionsEnabledKey); objectWillChange.send() }
    }

    var suggestionLedger: BotSuggestionLedger {
        get {
            if let ledger = suggestions.ledger { return ledger }
            let stored = defaults.data(forKey: Self.suggestionLedgerKey).flatMap { try? JSONDecoder().decode(BotSuggestionLedger.self, from: $0) }
            suggestions.ledger = stored ?? BotSuggestionLedger()
            return suggestions.ledger ?? BotSuggestionLedger()
        }
        set {
            var ledger = newValue; ledger.prune(now: now())
            suggestions.ledger = ledger
            if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.suggestionLedgerKey) }
        }
    }

    /// Days, hours and quiet hours in the Mac's time zone (`heartbeatTimeZone`; tests set it).
    var suggestionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = heartbeatTimeZone
        return calendar
    }

    // MARK: Suggested replies (any bot message)

    /// A message's chips work while it is a finished bot row that nothing in its chat has answered yet; a suggestion's
    /// while its record still waits for an answer (so no chip shows whose answer would not count).
    func canSendSuggestedReply(on message: ChatMessage, target: ConversationActionTarget) -> Bool {
        guard message.role == .assistant, !message.isStreaming, !message.suggestedReplies.isEmpty,
              let (_, conversation) = actionConversation(target), let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else { return false }
        if message.presentation == .suggestion {
            guard let id = message.metadata[SuggestionKey.record], suggestionLedger.records.contains(where: { $0.id.uuidString == id && $0.state == .asked }) else { return false }
        }
        return !conversation.messages[(index + 1)...].contains { $0.role == .user }
    }

    /// Sends a chip's text as the user's reply in the message's own chat (in a group, to the bot that wrote it).
    @discardableResult func sendSuggestedReply(_ reply: String, on message: ChatMessage, target: ConversationActionTarget) -> Bool {
        guard message.suggestedReplies.contains(reply), canSendSuggestedReply(on: message, target: target),
              let (bot, conversation) = actionConversation(target) else { return false }
        if let group = conversation as? GroupChat { return send(text: reply, to: group, recipientIDs: [message.authorID ?? bot.id]) }
        return send(text: reply, bot: bot, conversation: conversation, replyToID: nil,
                    metadata: [SuggestionKey.chip: "1", SuggestionKey.chipRow: message.id.uuidString])
    }

    // MARK: The answer

    /// The suggestion `user` may answer: the bot's newest suggestion row, with nothing but answers to it (the conversation
    /// about it) between it and `user`. A chip under it always may; a typed message within 12 hours of the question or the
    /// last answer; a chip under another message never. `answered`: an earlier answer already carried the question to the bot.
    func openSuggestion(in bot: Bot, for user: ChatMessage) -> (row: ChatMessage, id: UUID, answered: Bool)? {
        guard let index = bot.messages.lastIndex(where: { $0.presentation == .suggestion }) else { return nil }
        let row = bot.messages[index]
        guard let id = row.metadata[SuggestionKey.record].flatMap(UUID.init(uuidString:)) else { return nil }
        let between = bot.messages[(index + 1)...].filter { $0.role == .user && $0.id != user.id }
        guard between.allSatisfy({ $0.metadata[SuggestionKey.answers] == id.uuidString }) else { return nil }
        if user.metadata[SuggestionKey.chip] != nil {
            guard user.metadata[SuggestionKey.chipRow] == row.id.uuidString else { return nil }
        } else {
            guard now().timeIntervalSince(between.last?.createdAt ?? row.createdAt) <= Self.suggestionAnswerWindow else { return nil }
        }
        return (row, id, !between.isEmpty)
    }

    /// Called as `user` joins `conversation`. An answer to the open suggestion carries the record and the answer; the first
    /// one also carries the lead (the question and the routine offered) that the bot reads before the text. A no declines
    /// that request for good; a yes accepts it; "Different time" or a reply about the time, days or wording keeps the
    /// conversation about it open. The record's routine follows the conversation: first what the bot's latest reply in it
    /// offered (`adjusted(byBot:)`), then a time or days named in a yes or such a reply, so a bare yes to the bot's offer
    /// takes the offer. Not an answer: the same request asked again (the question was ignored) or another subject; those go
    /// to the bot as they are.
    func noteSuggestionAnswer(_ user: ChatMessage, bot: Bot, in conversation: any Conversation) {
        guard conversation === bot, user.role == .user, let open = openSuggestion(in: bot, for: user) else { return }
        var ledger = suggestionLedger
        guard let index = ledger.records.firstIndex(where: { $0.id == open.id }), ledger.records[index].state == .asked else { return }
        let answer = SuggestionAnswer.classify(user.content)
        if answer == .other, user.metadata[SuggestionKey.chip] == nil,
           AskText.similar(AskText.stems(user.content), Set(ledger.records[index].stems)) || !SuggestionAnswer.isAboutTheOffer(user.content) { return }
        user.metadata[SuggestionKey.answers] = open.id.uuidString
        user.metadata[SuggestionKey.answer] = answer.rawValue
        if !open.answered {
            user.metadata[SuggestionKey.lead] = BotSuggestionCopy.lead(question: open.row.content, draft: ledger.records[index].draft, timeZone: heartbeatTimeZone)
        }
        switch answer {
        case .no: ledger.records[index].state = .declined
        case .yes: ledger.records[index].state = .accepted
        case .other: break
        }
        if answer != .no {
            var draft = ledger.records[index].draft
            if open.answered, let offer = latestOffer(in: bot, before: user) { draft = draft.adjusted(byBot: offer.content) }
            ledger.records[index].draft = draft.adjusted(by: user.content)
        }
        suggestionLedger = ledger
    }

    /// The bot's reply to the last answer before `user`: its latest finished text row after that answer.
    func latestOffer(in bot: Bot, before user: ChatMessage) -> ChatMessage? {
        let end = bot.messages.firstIndex { $0.id == user.id } ?? bot.messages.endIndex
        let earlier = bot.messages[..<end]
        guard let answer = earlier.lastIndex(where: { $0.role == .user }) else { return nil }
        return earlier[(answer + 1)...].last { $0.role == .assistant && $0.presentation == .text && !$0.isStreaming && !$0.content.isEmpty }
    }

    // MARK: After a turn

    /// After a turn in a bot's main chat: follow a yes through (whatever the turn's end, so a failed or stopped turn
    /// still falls back to the editor), else, after a finished turn, look for a repeated ask.
    func afterSuggestionTurn(bot: Bot, reply: ChatMessage, finished: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let answered = await self.followThroughSuggestion(bot: bot, reply: reply)
            if answered || !finished { return }
            await self.suggestRoutineIfRepeated(bot: bot)
        }
    }

    /// The turn `reply` ends answered a suggestion (true). After a yes the routines are read again: an enabled one on the
    /// agreed schedule that does the ask (or the agreed prompt) means the bot made it (none did when it was asked);
    /// otherwise, or when they cannot be read, the routine editor opens in the bot's chat prefilled with the routine the
    /// conversation settled on (the fallback). A cron tool step alone proves nothing: it may only have listed the jobs; a
    /// routine at another time, or paused, is not the one agreed.
    @discardableResult func followThroughSuggestion(bot: Bot, reply: ChatMessage) async -> Bool {
        guard let position = bot.messages.firstIndex(where: { $0.id == reply.id }),
              let user = bot.messages[..<position].last(where: { $0.role == .user }), let answer = user.metadata[SuggestionKey.answer] else { return false }
        guard answer == SuggestionAnswer.yes.rawValue, user.metadata[SuggestionKey.followed] == nil,
              let id = user.metadata[SuggestionKey.answers].flatMap(UUID.init(uuidString:)),
              let record = suggestionLedger.records.first(where: { $0.id == id }) else { return true }
        user.metadata[SuggestionKey.followed] = "1"; save()
        let draft = record.draft, asks = [Set(record.stems), AskText.stems(draft.prompt)]
        let made = await knownRoutines(for: bot)?.contains { routine in
            routine.enabled && CronDays.same(routine.schedule, draft.schedule) && asks.contains { AskText.covered($0, by: AskText.stems(routine.text)) }
        } == true
        if !made { suggestions.editor = draft; objectWillChange.send() }
        return true
    }

    // MARK: Asking

    /// When the newest ask in `bot`'s main chat repeats, no routine covers it and the rules allow, posts the bot's question
    /// with its quick replies. Returns the posted row.
    @discardableResult func suggestRoutineIfRepeated(bot: Bot) async -> ChatMessage? {
        guard bot.backend != .openClaw, !bot.isDemo, !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly, !bot.retiredOnBox,
              !suggestions.evaluating.contains(bot.id), let repeated = allowedRepeat(in: bot) else { return nil }
        suggestions.evaluating.insert(bot.id); defer { suggestions.evaluating.remove(bot.id) }
        guard let existing = await knownRoutines(for: bot),
              !existing.contains(where: { AskText.covered(repeated.anchor.stems, by: AskText.stems($0.text)) }),
              // The chat may have moved on, or another suggestion gone out, while the routines were read.
              isIdle(bot), allowedRepeat(in: bot)?.anchor.id == repeated.anchor.id else { return nil }
        let postedAt = now(), draft = RoutineDraft.make(for: repeated, botID: bot.id, calendar: suggestionCalendar)
        var ledger = suggestionLedger
        let earlier = SuggestionPolicy.records(ledger, botID: bot.id, stems: repeated.anchor.stems).first { $0.state == .asked }
        let id = earlier?.id ?? UUID()
        let row = ChatMessage(role: .assistant, content: BotSuggestionCopy.question(repeated, draft: draft, now: postedAt), createdAt: postedAt,
                              presentation: .suggestion, metadata: [SuggestionKey.record: id.uuidString])
        row.suggestedReplies = BotSuggestionCopy.replies(draft)
        let record = BotSuggestionRecord(id: id, botID: bot.id, stems: repeated.anchor.stems.sorted(), example: repeated.anchor.text, askedAt: postedAt,
                                         state: .asked, messageID: row.id, draft: draft)
        ledger.records.removeAll { $0.id == id }; ledger.records.append(record); ledger.posted.append(postedAt)
        suggestionLedger = ledger
        bot.messages.append(row)
        if selectedBot?.id != bot.id || openThread(in: bot) != nil || NSApp?.isActive != true { bot.unreadCount += 1 }
        objectWillChange.send(); save()
        return row
    }

    /// The repeat of the newest ask, when the setting, quiet hours, the daily cap and earlier answers allow asking now.
    func allowedRepeat(in bot: Bot) -> RepeatedAsk? {
        let at = now(), calendar = suggestionCalendar
        guard let repeated = RepeatedAskDetector.detect(bot.messages, now: at, calendar: calendar),
              SuggestionPolicy.refusal(stems: repeated.anchor.stems, botID: bot.id, ledger: suggestionLedger, enabled: suggestionsEnabled,
                                       now: at, calendar: calendar) == nil else { return nil }
        return repeated
    }

    /// Every routine that could already cover an ask (name and prompt, schedule, on or paused): the server's jobs, read
    /// now, for a Hermes bot (plus routines not on the server yet), the local list otherwise. Nil when the jobs cannot be
    /// read now (the list kept from an earlier read does not count), so a duplicate is never offered.
    func knownRoutines(for bot: Bot) async -> [KnownRoutine]? {
        let local = bot.routines.map { KnownRoutine(text: $0.name + "\n" + $0.prompt, schedule: $0.schedule, enabled: $0.isEnabled) }
        guard bot.backend == .hermes else { return local }
        guard await refreshRoutines(for: bot), let jobs = routines.state(for: bot.id).jobs.value else { return nil }
        return local + jobs.map { KnownRoutine(text: $0.name + "\n" + $0.prompt, schedule: $0.schedule, enabled: !$0.isPaused) }
    }
}

/// A routine as the suggestion checks read it.
struct KnownRoutine: Equatable, Sendable {
    var text: String; var schedule: String; var enabled: Bool
}

import Foundation
import Testing
@testable import AgentApp

// recs1: a repeated ask becomes a normal message from the bot with quick replies; the answer goes to the bot with the
// question; a no is for good, silence pauses a week, a yes the bot did not act on opens the prefilled editor.
@MainActor struct BotSuggestionFlowTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// The user's ask and the bot's answer half a minute later.
    private static func exchange(_ text: String, _ at: Date) -> [ChatMessage] {
        [ChatMessage(role: .user, content: text, createdAt: at), ChatMessage(role: .assistant, content: "Here it is.", createdAt: at.addingTimeInterval(30))]
    }

    /// Monday, Tuesday and Wednesday (2026-10-19…21) at 9:30 UTC: the inbox summary, worded two ways.
    private static func week(month: Int = 10, days: [Int] = [19, 20, 21]) -> [ChatMessage] {
        days.enumerated().flatMap { index, day in exchange(index == 1 ? "summarise my inbox please" : "Summarize my inbox", date(day, 9, 30, month: month)) }
    }

    /// A store at Wednesday 2026-10-21 10:00 UTC whose bot Ada has asked for the summary on three days.
    private func repeatingStore(backend: GroupBackend = GroupBackend(name: "Ada"), defaults: UserDefaults = isolatedDefaults(), url: URL = temporaryStore(),
                                now: Date = BotSuggestionFlowTests.date(21, 10)) -> (AppStore, Bot) {
        let store = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: defaults)
        store.heartbeatTimeZone = Self.utc; store.now = { now }
        let bot = Bot(name: "Ada"); bot.messages = Self.week()
        store.bots = [bot]
        return (store, bot)
    }

    @Test func aRepeatedAskBecomesOneQuestionFromTheBot() async throws {
        let defaults = isolatedDefaults(), url = temporaryStore()
        let (store, bot) = repeatingStore(defaults: defaults, url: url)
        #expect(store.suggestionsEnabled, "on by default")
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(row.role == .assistant && row.presentation == .suggestion && bot.messages.last === row)
        #expect(row.content == "You've asked me for “Summarize my inbox” 3 times this week. Want me to run it every weekday at 9:00?")
        #expect(row.suggestedReplies == ["Yes, every weekday at 9:00", "Different time", "No thanks"])
        #expect(store.canSendSuggestedReply(on: row, target: .bot(botID: bot.id, threadID: nil)))
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil, "asked once")
        // Kept on the Mac: the record in the settings, the row with its replies in the chats.
        let reopened = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
        #expect(reopened.suggestionLedger.records.map(\.state) == [.asked] && reopened.suggestionLedger.records.first?.messageID == row.id)
        let restored = try #require(reopened.bots.first { $0.id == bot.id }?.messages.first { $0.id == row.id })
        #expect(restored.presentation == .suggestion && restored.suggestedReplies == row.suggestedReplies)
    }

    @Test func aRoutineThatAlreadyDoesItStopsTheQuestion() async {
        let (store, bot) = repeatingStore()
        bot.routines = [BotRoutine(name: "Inbox digest", schedule: "0 9 * * *", prompt: "Summarize my inbox and flag urgent mail")]
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil)
        #expect(!bot.messages.contains { $0.presentation == .suggestion })
    }

    @Test func theSwitchQuietHoursAndTheDailyCapHoldItBack() async {
        let (off, offBot) = repeatingStore(); off.suggestionsEnabled = false
        #expect(await off.suggestRoutineIfRepeated(bot: offBot) == nil)
        let (late, lateBot) = repeatingStore(now: Self.date(21, 23, 30))
        #expect(await late.suggestRoutineIfRepeated(bot: lateBot) == nil, "none 23:00–08:00")
        let (store, first) = repeatingStore()
        let others = (1...3).map { index in let bot = Bot(name: "Bot \(index)"); bot.messages = Self.week(); return bot }
        store.bots = [first] + others
        var posted: [Bot] = []
        for bot in store.bots { if await store.suggestRoutineIfRepeated(bot: bot) != nil { posted.append(bot) } }
        #expect(posted.count == 3 && !posted.contains { $0 === others[2] }, "three a day across all bots")
        store.now = { Self.date(22, 10) }
        #expect(await store.suggestRoutineIfRepeated(bot: others[2]) != nil, "the next day it may")
    }

    @Test func noThanksGoesToTheBotAndDeclinesForGood() async throws {
        let backend = GroupBackend(name: "Ada")
        let (store, bot) = repeatingStore(backend: backend)
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        let target = ConversationActionTarget.bot(botID: bot.id, threadID: nil)
        #expect(!store.sendSuggestedReply("Maybe", on: row, target: target), "only an offered reply")
        #expect(store.sendSuggestedReply("No thanks", on: row, target: target))
        try await waitUntil { !store.anyTurnRunning }
        let answer = try #require(bot.messages.last { $0.role == .user })
        #expect(answer.content == "No thanks" && answer.metadata[SuggestionKey.answer] == "no")
        #expect(answer.outgoingText.hasPrefix("(SwarmHub asked this in your chat for you: \"\(row.content)\"") && answer.outgoingText.hasSuffix("\nNo thanks"))
        #expect(backend.sent.all.last?.text == answer.outgoingText, "the bot reads the question with the answer")
        #expect(store.suggestionLedger.records.first?.state == .declined)
        #expect(!store.canSendSuggestedReply(on: row, target: target), "answered: the chips go")
        // A month later the same request on three more days: never asked again.
        bot.messages += Self.week(month: 11)
        store.now = { Self.date(21, 10, month: 11) }
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil)
        #expect(store.suggestions.editor == nil, "nothing to create after a no")
    }

    @Test func anUnansweredQuestionWaitsAWeek() async throws {
        let (store, bot) = repeatingStore()
        let first = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        let id = try #require(store.suggestionLedger.records.first?.id)
        bot.messages += Self.exchange("Summarize my inbox", Self.date(22, 9, 30))
        store.now = { Self.date(22, 10) }
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil, "a day later")
        bot.messages += Self.week(days: [27, 28, 29])
        store.now = { Self.date(29, 10) }
        let second = try #require(await store.suggestRoutineIfRepeated(bot: bot), "eight days later")
        let records = store.suggestionLedger.records
        #expect(second.id != first.id && records.count == 1 && records[0].id == id && records[0].messageID == second.id && records[0].state == .asked)
    }

    @Test func aYesTheBotDidNotActOnOpensThePrefilledEditor() async throws {
        let backend = GroupBackend(name: "Ada")
        let (store, bot) = repeatingStore(backend: backend)
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.sendSuggestedReply("Yes, every weekday at 9:00", on: row, target: .bot(botID: bot.id, threadID: nil)))
        try await waitUntil { store.suggestions.editor != nil }
        let draft = try #require(store.suggestions.editor)
        #expect(draft.botID == bot.id && draft.schedule == "0 9 * * 1-5" && draft.prompt == "Summarize my inbox" && draft.name == "Summarize my inbox")
        #expect(store.suggestionLedger.records.first?.state == .accepted)
        #expect(backend.sent.all.last?.text.contains("If my answer below is yes, create that routine now") == true)
        #expect(bot.messages.last { $0.role == .user }?.metadata[SuggestionKey.followed] == "1")
    }

    /// recs1b-fix 1: a cron step is not proof (it may only have listed the jobs); the jobs read again after the turn are.
    @Test func aYesIsDoneOnlyWhenTheJobsReadAgainHoldTheRoutine() async throws {
        let server = FakeJobsServer()
        let (store, bot, _) = routinesStore(server)
        let draft = RoutineDraft(botID: bot.id, name: "Summarize my inbox", schedule: "0 9 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 9)
        let record = BotSuggestionRecord(botID: bot.id, stems: AskText.stems("Summarize my inbox").sorted(), example: "Summarize my inbox", askedAt: Self.date(21, 10),
                                         state: .accepted, messageID: UUID(), draft: draft)
        store.suggestionLedger = BotSuggestionLedger(records: [record])
        func yesTurn(reply text: String) -> (ChatMessage, ChatMessage) {
            let yes = ChatMessage(role: .user, content: "Yes", metadata: [SuggestionKey.answers: record.id.uuidString, SuggestionKey.answer: "yes"])
            let reply = ChatMessage(role: .assistant, content: text)
            var activity = ToolActivity()
            activity.steps = [ToolStep(name: "cronjob", preview: nil, startedAt: Self.date(21, 10), finishedAt: Self.date(21, 10))]
            reply.activity = activity
            bot.messages += [yes, reply]
            return (yes, reply)
        }
        // The bot's cron step only listed the jobs: nothing on the server does the ask, so the editor opens.
        let (listed, listing) = yesTurn(reply: "You have no routines yet.")
        #expect(await store.followThroughSuggestion(bot: bot, reply: listing))
        #expect(store.suggestions.editor == draft && listed.metadata[SuggestionKey.followed] == "1")
        store.suggestions.editor = nil
        // The bot made it: the jobs read now hold it, so the editor stays closed.
        server.add(jobPayload(id: "a1", name: "Inbox summary", schedule: "0 9 * * 1-5", prompt: "Summarize my inbox and flag anything urgent"))
        let (made, done) = yesTurn(reply: "Done: it runs every weekday at 9:00.")
        #expect(await store.followThroughSuggestion(bot: bot, reply: done))
        #expect(store.suggestions.editor == nil && made.metadata[SuggestionKey.followed] == "1")
        // The jobs cannot be read: not proof either, the editor opens.
        server.listStatus = 500
        let (unread, unreadReply) = yesTurn(reply: "Done.")
        #expect(await store.followThroughSuggestion(bot: bot, reply: unreadReply))
        #expect(store.suggestions.editor == draft && unread.metadata[SuggestionKey.followed] == "1")
    }

    /// recs1b-fix2 1: a routine that does the ask at another time than agreed, or paused, is not the one agreed: the editor
    /// opens. One on the agreed schedule (its days written as names) is.
    @Test func onlyAnEnabledRoutineOnTheAgreedScheduleCountsAsMade() async {
        func editorAfterYes(with job: [String: Any]) async -> RoutineDraft? {
            let server = FakeJobsServer(); server.add(job)
            let (store, bot, _) = routinesStore(server)
            let draft = RoutineDraft(botID: bot.id, name: "Summarize my inbox", schedule: "30 7 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 7)
            let record = BotSuggestionRecord(botID: bot.id, stems: AskText.stems("Summarize my inbox").sorted(), example: "Summarize my inbox", askedAt: Self.date(21, 10),
                                             state: .accepted, messageID: UUID(), draft: draft)
            store.suggestionLedger = BotSuggestionLedger(records: [record])
            let reply = ChatMessage(role: .assistant, content: "Done.")
            bot.messages += [ChatMessage(role: .user, content: "Yes", metadata: [SuggestionKey.answers: record.id.uuidString, SuggestionKey.answer: "yes"]), reply]
            #expect(await store.followThroughSuggestion(bot: bot, reply: reply))
            return store.suggestions.editor
        }
        let prompt = "Summarize my inbox and flag anything urgent"
        let early = await editorAfterYes(with: jobPayload(id: "a1", name: "Inbox summary", schedule: "0 9 * * 1-5", prompt: prompt))
        #expect(early?.schedule == "30 7 * * 1-5", "made at the first offer's time, not the agreed one")
        let paused = await editorAfterYes(with: jobPayload(id: "a2", name: "Inbox summary", schedule: "30 7 * * 1-5", prompt: prompt, enabled: false))
        #expect(paused?.schedule == "30 7 * * 1-5", "made paused")
        #expect(await editorAfterYes(with: jobPayload(id: "a3", name: "Inbox summary", schedule: "30 7 * * mon-fri", prompt: prompt)) == nil, "made as agreed")
    }

    /// recs1b-fix 2: when the jobs cannot be read now, the list kept from an earlier read does not count.
    @Test func jobsThatCannotBeReadNowAskNothing() async throws {
        let server = FakeJobsServer()
        let (store, bot, _) = routinesStore(server)
        store.heartbeatTimeZone = Self.utc; store.now = { Self.date(21, 10) }
        bot.messages = Self.week()
        let read = await store.refreshRoutines(for: bot)
        #expect(read && store.routines.state(for: bot.id).jobs.value?.isEmpty == true, "an earlier read: no jobs")
        server.listStatus = 500
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil, "the routine may have been made since")
        #expect(!bot.messages.contains { $0.presentation == .suggestion })
        server.listStatus = 200
        #expect(await store.suggestRoutineIfRepeated(bot: bot) != nil, "read again, still none: it asks")
    }

    /// recs1b-fix 3: the chips show until something answers the question, so a tap counts however late it comes.
    @Test func aChipCountsHoweverLateItIsTapped() async throws {
        let target = { (bot: Bot) in ConversationActionTarget.bot(botID: bot.id, threadID: nil) }
        let (store, bot) = repeatingStore()
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        store.now = { Self.date(23, 10) }
        #expect(store.canSendSuggestedReply(on: row, target: target(bot)), "two days later the chips still show")
        #expect(store.sendSuggestedReply("No thanks", on: row, target: target(bot)))
        try await waitUntil { !store.anyTurnRunning }
        let no = try #require(bot.messages.last { $0.role == .user })
        #expect(no.metadata[SuggestionKey.answer] == "no" && no.outgoingText.hasPrefix("(SwarmHub asked this in your chat for you:"))
        #expect(store.suggestionLedger.records.first?.state == .declined, "a late no is still for good")

        let (yesStore, yesBot) = repeatingStore()
        let yesRow = try #require(await yesStore.suggestRoutineIfRepeated(bot: yesBot))
        yesStore.now = { Self.date(23, 10) }
        #expect(yesStore.sendSuggestedReply("Yes, every weekday at 9:00", on: yesRow, target: target(yesBot)))
        try await waitUntil { yesStore.suggestions.editor != nil }
        let yes = try #require(yesBot.messages.last { $0.role == .user })
        #expect(yes.metadata[SuggestionKey.answer] == "yes" && yes.outgoingText.hasPrefix("(SwarmHub asked this in your chat for you:"))
        #expect(yesStore.suggestions.editor?.schedule == "0 9 * * 1-5" && yesStore.suggestionLedger.records.first?.state == .accepted)
    }

    /// recs1b-fix 3: a typed answer counts within 12 hours of the last answer, not only of the question; a chip under
    /// another message is not an answer, and a question whose record is gone shows no chips.
    @Test func theConversationAboutItStaysOpenFromItsLastAnswer() async throws {
        let (store, bot) = repeatingStore()
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        let id = try #require(store.suggestionLedger.records.first?.id)
        let later = ChatMessage(role: .user, content: "Make it 7:30 instead", createdAt: Self.date(21, 21),
                                metadata: [SuggestionKey.answers: id.uuidString, SuggestionKey.answer: "other"])
        bot.messages += [later, ChatMessage(role: .assistant, content: "7:30 on weekdays, then?", createdAt: Self.date(21, 21, 1))]
        store.now = { Self.date(22, 8) }
        let yes = ChatMessage(role: .user, content: "Yes", createdAt: Self.date(22, 8))
        bot.messages.append(yes); store.noteSuggestionAnswer(yes, bot: bot, in: bot)
        #expect(yes.metadata[SuggestionKey.answer] == "yes" && store.suggestionLedger.records.first?.state == .accepted, "22 h after the question, 11 h after the last answer")

        let (other, otherBot) = repeatingStore()
        _ = try #require(await other.suggestRoutineIfRepeated(bot: otherBot))
        let card = ChatMessage(role: .assistant, content: "Tea or coffee?"); card.suggestedReplies = ["Tea", "No thanks"]
        otherBot.messages.append(card)
        let tapped = ChatMessage(role: .user, content: "No thanks", metadata: [SuggestionKey.chip: "1", SuggestionKey.chipRow: card.id.uuidString])
        otherBot.messages.append(tapped); other.noteSuggestionAnswer(tapped, bot: otherBot, in: otherBot)
        #expect(tapped.metadata[SuggestionKey.answer] == nil && other.suggestionLedger.records.first?.state == .asked)

        let (gone, goneBot) = repeatingStore()
        let goneRow = try #require(await gone.suggestRoutineIfRepeated(bot: goneBot))
        let goneTarget = ConversationActionTarget.bot(botID: goneBot.id, threadID: nil)
        #expect(gone.canSendSuggestedReply(on: goneRow, target: goneTarget))
        gone.suggestionLedger = BotSuggestionLedger()
        #expect(!gone.canSendSuggestedReply(on: goneRow, target: goneTarget), "its answer could not be recorded, so no chips")
    }

    @Test func aTypedAnswerCarriesTheQuestion() async throws {
        let backend = GroupBackend(name: "Ada")
        let (store, bot) = repeatingStore(backend: backend)
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.send(text: "Make it 7:30 instead", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let typed = try #require(bot.messages.last { $0.role == .user })
        #expect(typed.metadata[SuggestionKey.answer] == "other")
        #expect(typed.outgoingText.hasPrefix("(SwarmHub asked") && typed.outgoingText.hasSuffix("\nMake it 7:30 instead") && typed.content == "Make it 7:30 instead")
        #expect(store.suggestionLedger.records.first?.state == .asked, "settled in the conversation, not declined")
        #expect(store.suggestions.editor == nil, "the editor opens only after a yes")
        // The conversation about it goes on: the later yes is its answer; the question already reached the bot.
        #expect(store.send(text: "Yes, do that", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { store.suggestions.editor != nil }
        let yes = try #require(bot.messages.last { $0.role == .user })
        #expect(yes.metadata[SuggestionKey.answer] == "yes" && yes.outgoingText == "Yes, do that")
        #expect(store.suggestionLedger.records.first?.state == .accepted)
        // recs1b-fix 4: the editor opens with what the conversation settled on, not the first offer.
        let editor = try #require(store.suggestions.editor)
        #expect(editor.schedule == "30 7 * * 1-5" && editor.hour == 7 && editor.minute == 30 && editor.when == "every weekday at 7:30")
        #expect(editor.name == "Summarize my inbox" && editor.prompt == "Summarize my inbox" && editor.botID == bot.id)
    }

    /// recs1b-fix2 3: a bare yes to the bot's own offer opens the editor with that offer: its `Routine:` line (name, schedule,
    /// prompt) when it wrote one, else the one time and the days it named.
    @Test func aBareYesTakesTheBotsLatestOffer() async throws {
        func editorAfterYes(to offer: String) async throws -> RoutineDraft {
            let (store, bot) = repeatingStore()
            let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
            #expect(store.sendSuggestedReply(BotSuggestionCopy.differentTime, on: row, target: .bot(botID: bot.id, threadID: nil)))
            try await waitUntil { !store.anyTurnRunning }
            bot.messages.append(ChatMessage(role: .assistant, content: offer))
            #expect(store.send(text: "yes", bot: bot, conversation: bot, replyToID: nil))
            try await waitUntil { store.suggestions.editor != nil }
            return try #require(store.suggestions.editor)
        }
        let worded = try await editorAfterYes(to: """
            How about Mondays, Wednesdays and Fridays at 7:30 instead of 9:00, flagging urgent mail too?
            **Routine:** name "Inbox digest", schedule `30 7 * * 1,3,5`, prompt "Summarize my inbox and flag urgent mail"
            """)
        #expect(worded.name == "Inbox digest" && worded.prompt == "Summarize my inbox and flag urgent mail")
        #expect(worded.schedule == "30 7 * * 1,3,5" && worded.hour == 7 && worded.when == "every Monday, Wednesday and Friday at 7:30")
        let timed = try await editorAfterYes(to: "Sure, every weekday at 7:30 instead of 9:00. Shall I set it up?")
        #expect(timed.schedule == "30 7 * * 1-5" && timed.name == "Summarize my inbox" && timed.prompt == "Summarize my inbox")
        let unsure = try await editorAfterYes(to: "What time suits you: 7:00, 7:30 or 8:00?")
        #expect(unsure.schedule == "0 9 * * 1-5", "several times named: none is taken")
    }

    /// recs1b-fix3: a reply that only names days ("Mon/Wed/Fri", "only on Tuesdays and Thursdays") is about the offer, so
    /// the chat carries it as an answer and a later bare yes opens the editor on those days.
    private func editorAfterDays(_ days: String) async throws -> (answer: ChatMessage, editor: RoutineDraft) {
        let (store, bot) = repeatingStore()
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.send(text: days, bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let answer = try #require(bot.messages.last { $0.role == .user })
        #expect(answer.metadata[SuggestionKey.answer] == "other" && answer.outgoingText.hasPrefix("(SwarmHub asked"))
        #expect(store.send(text: "yes", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { store.suggestions.editor != nil }
        #expect(store.suggestionLedger.records.first?.state == .accepted)
        return (answer, try #require(store.suggestions.editor))
    }

    @Test func namedDaysThenYesOpenTheEditorOnThoseDays() async throws {
        let (answer, editor) = try await editorAfterDays("Mon/Wed/Fri")
        #expect(answer.content == "Mon/Wed/Fri")
        #expect(editor.schedule == "0 9 * * 1,3,5" && editor.when == "every Monday, Wednesday and Friday at 9:00" && !editor.weekdaysOnly)
        #expect(editor.name == "Summarize my inbox" && editor.prompt == "Summarize my inbox")
    }

    @Test func onlyOnTuesdaysAndThursdaysThenYesOpensTheEditorOnThoseDays() async throws {
        let (answer, editor) = try await editorAfterDays("only on Tuesdays and Thursdays")
        #expect(answer.content == "only on Tuesdays and Thursdays")
        #expect(editor.schedule == "0 9 * * 2,4" && editor.when == "every Tuesday and Thursday at 9:00" && !editor.weekdaysOnly)
        #expect(editor.name == "Summarize my inbox" && editor.prompt == "Summarize my inbox")
    }

    /// recs1b-fix4: a short day name inside another subject ("sat", "sun") is not an answer, so a later yes leaves the
    /// offer as it was: still asked, still every weekday, no editor.
    private func yesAfterAnotherSubject(_ text: String) async throws {
        let backend = GroupBackend(name: "Ada")
        let (store, bot) = repeatingStore(backend: backend)
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.send(text: text, bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let other = try #require(bot.messages.last { $0.role == .user })
        #expect(other.metadata[SuggestionKey.answer] == nil && backend.sent.all.last?.text == text)
        #expect(store.send(text: "yes", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let record = try #require(store.suggestionLedger.records.first)
        #expect(record.state == .asked && record.draft.schedule == "0 9 * * 1-5" && store.suggestions.editor == nil)
    }

    @Test func iSatDownToWorkThenYesKeepsTheOfferedDays() async throws { try await yesAfterAnotherSubject("I sat down to work") }

    @Test func theSunIsOutTodayThenYesKeepsTheOfferedDays() async throws { try await yesAfterAnotherSubject("the sun is out today") }

    @Test func anotherSubjectIsNotAnAnswer() async throws {
        let backend = GroupBackend(name: "Ada")
        let (store, bot) = repeatingStore(backend: backend)
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.send(text: "What's the weather in Warsaw?", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let other = try #require(bot.messages.last { $0.role == .user })
        #expect(other.metadata[SuggestionKey.answer] == nil && backend.sent.all.last?.text == "What's the weather in Warsaw?")
        #expect(store.suggestionLedger.records.first?.state == .asked)
    }

    @Test func askingTheSameThingAgainIsNotAnAnswer() async throws {
        let (store, bot) = repeatingStore()
        _ = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(store.send(text: "Summarize my inbox", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { !store.anyTurnRunning }
        let again = try #require(bot.messages.last { $0.role == .user })
        #expect(again.metadata[SuggestionKey.answer] == nil && again.outgoingText == "Summarize my inbox")
        #expect(store.suggestionLedger.records.first?.state == .asked)
    }

    @Test func suggestedRepliesWorkOnAnyBotMessage() async throws {
        let backend = GroupBackend(name: "Ada")
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Ada"); store.bots = [bot]
        let question = ChatMessage(role: .assistant, content: "Tea or coffee?")
        question.suggestedReplies = ["Tea", "Coffee"]
        bot.messages = [question]
        let target = ConversationActionTarget.bot(botID: bot.id, threadID: nil)
        #expect(store.canSendSuggestedReply(on: question, target: target))
        #expect(!store.sendSuggestedReply("Juice", on: question, target: target))
        #expect(store.sendSuggestedReply("Coffee", on: question, target: target))
        try await waitUntil { !store.anyTurnRunning }
        let sent = try #require(bot.messages.first { $0.role == .user })
        #expect(sent.content == "Coffee" && sent.outgoingText == "Coffee" && sent.metadata[SuggestionKey.chip] == "1")
        #expect(backend.sent.all.map { $0.text } == ["Coffee"])
        #expect(!store.canSendSuggestedReply(on: question, target: target) && !store.sendSuggestedReply("Tea", on: question, target: target), "answered")
    }

    @Test func theThirdAskOnAThirdDayGetsTheQuestionAfterTheReply() async throws {
        let backend = GroupBackend(name: "Ada")
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        // A zone where it is midday now, so the quiet hours never apply to this test.
        let now = Date()
        var utcCalendar = Calendar(identifier: .gregorian); utcCalendar.timeZone = Self.utc
        store.heartbeatTimeZone = TimeZone(secondsFromGMT: (12 - utcCalendar.component(.hour, from: now)) * 3600)!
        let bot = Bot(name: "Ada"); store.bots = [bot]
        bot.messages = Self.exchange("Summarize my inbox", now.addingTimeInterval(-2 * 86_400)) + Self.exchange("summarise my inbox please", now.addingTimeInterval(-86_400))
        #expect(store.send(text: "Summarize my inbox", bot: bot, conversation: bot, replyToID: nil))
        try await waitUntil { bot.messages.contains { $0.presentation == .suggestion } }
        let row = try #require(bot.messages.last)
        #expect(row.presentation == .suggestion && row.content.hasPrefix("You've asked me for “Summarize my inbox” 3 times this week."))
        #expect(bot.messages.dropLast().last?.role == .assistant && bot.messages.dropLast().last?.content == "Ada says hi", "after the bot's reply")
    }
}

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

    @Test func aYesTheBotActedOnLeavesTheEditorClosed() async {
        let (store, bot) = repeatingStore()
        let draft = RoutineDraft(botID: bot.id, name: "Summarize my inbox", schedule: "0 9 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 9)
        let record = BotSuggestionRecord(botID: bot.id, stems: ["inbox", "summa"], example: "Summarize my inbox", askedAt: Self.date(21, 10), state: .accepted,
                                         messageID: UUID(), draft: draft)
        store.suggestionLedger = BotSuggestionLedger(records: [record])
        let yes = ChatMessage(role: .user, content: "Yes", metadata: [SuggestionKey.answers: record.id.uuidString, SuggestionKey.answer: "yes"])
        let reply = ChatMessage(role: .assistant, content: "Done: it runs every weekday at 9:00.")
        var activity = ToolActivity()
        activity.steps = [ToolStep(name: "cronjob", preview: nil, startedAt: Self.date(21, 10), finishedAt: Self.date(21, 10))]
        reply.activity = activity
        bot.messages += [yes, reply]
        #expect(await store.followThroughSuggestion(bot: bot, reply: reply))
        #expect(store.suggestions.editor == nil && yes.metadata[SuggestionKey.followed] == "1")
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
    }

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

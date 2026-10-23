import Foundation
import Testing
@testable import AgentApp

// recs1: the repeated-ask detector, the anti-annoyance rules, the answers and the words of a suggestion. Pure: fixed dates
// in UTC (2026-10-19 is a Monday), no store.

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utcCalendar().date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

@MainActor private func ask(_ text: String, _ date: Date, metadata: [String: String] = [:]) -> ChatMessage {
    ChatMessage(role: .user, content: text, createdAt: date, metadata: metadata)
}

private func repeated(_ dates: [Date], text: String = "Summarize my inbox?") -> RepeatedAsk {
    let asks = dates.map { Ask(id: UUID(), text: text, at: $0, stems: AskText.stems(text)) }
    return RepeatedAsk(anchor: asks[asks.count - 1], asks: asks, days: dates.count)
}

@Test func similarAsksMeetAcrossWordingsAndDifferentAsksDoNot() {
    let inbox = AskText.stems("Summarize my inbox")
    #expect(inbox == ["summa", "inbox"])
    #expect(AskText.similar(inbox, AskText.stems("Can you summarise my inbox, please?")))
    #expect(!AskText.similar(inbox, AskText.stems("Summarize the news")))
    #expect(AskText.stems("Thanks!").isEmpty && AskText.stems("ok, continue").isEmpty)
    #expect(AskText.similar(AskText.stems("Podsumuj moją skrzynkę"), AskText.stems("podsumuj moja skrzynke prosze")))
}

@MainActor @Test func threeDistinctDaysWithinFourteenDaysAreARepeat() throws {
    let calendar = utcCalendar(), now = at(21, 10)
    let rows = [ask("Summarize my inbox", at(19, 9, 30)), ChatMessage(role: .assistant, content: "Done.", createdAt: at(19, 9, 31)),
                ask("summarise my inbox please", at(20, 9, 30)), ask("Summarize my inbox", at(21, 9, 30))]
    let found = try #require(RepeatedAskDetector.detect(rows, now: now, calendar: calendar))
    #expect(found.days == 3 && found.asks.count == 3 && found.anchor.text == "Summarize my inbox")
    let twoOnOneDay = [ask("Summarize my inbox", at(20, 8)), ask("Summarize my inbox", at(20, 18)), ask("Summarize my inbox", at(21, 9))]
    #expect(RepeatedAskDetector.detect(twoOnOneDay, now: now, calendar: calendar) == nil, "two asks on one day are one day")
    let fifteenDays = [ask("Summarize my inbox", at(6, 9)), ask("Summarize my inbox", at(20, 9)), ask("Summarize my inbox", at(21, 9))]
    #expect(RepeatedAskDetector.detect(fifteenDays, now: now, calendar: calendar) == nil, "outside the 14 days")
    let thirteenDays = [ask("Summarize my inbox", at(8, 11)), ask("Summarize my inbox", at(20, 9)), ask("Summarize my inbox", at(21, 9))]
    #expect(RepeatedAskDetector.detect(thirteenDays, now: now, calendar: calendar) != nil)
    #expect(RepeatedAskDetector.detect(rows + [ask("What's the weather in Warsaw", at(21, 9, 45))], now: now, calendar: calendar) == nil,
            "the newest ask must be the repeat")
    #expect(RepeatedAskDetector.detect([ask("Inbox", at(19, 9)), ask("Inbox", at(20, 9)), ask("Inbox", at(21, 9))], now: now, calendar: calendar) == nil,
            "one word is too little to go on")
}

@MainActor @Test func steersAutomationsSlashCommandsAndAnswersAreNotAsks() {
    let date = at(21, 9)
    #expect(RepeatedAskDetector.isAsk(ask("Summarize my inbox", date)))
    for key in [SteerKey.steer, SteerKey.correction, SteerKey.outOfBand, SlashKey.line, AutomationKey.woken, AutomationKey.orientation,
                SuggestionKey.chip, SuggestionKey.answer] {
        #expect(!RepeatedAskDetector.isAsk(ask("Summarize my inbox", date, metadata: [key: "1"])), "\(key)")
    }
    #expect(!RepeatedAskDetector.isAsk(ask("/goal summarize my inbox", date)))
    #expect(!RepeatedAskDetector.isAsk(ask(String(repeating: "inbox ", count: 60), date)), "pasted material")
    #expect(!RepeatedAskDetector.isAsk(ChatMessage(role: .assistant, content: "Summarize my inbox", createdAt: date)))
}

@Test func aRoutineThatHoldsTheAskCoversIt() {
    let inbox = AskText.stems("Summarize my inbox")
    #expect(AskText.covered(inbox, by: AskText.stems("Inbox digest\nEvery morning, summarize my inbox and flag anything urgent.")))
    #expect(!AskText.covered(inbox, by: AskText.stems("News\nSummarize the news")))
}

@Test func theScheduleFollowsTheDaysAndTheMedianTime() {
    let calendar = utcCalendar()
    let weekdays = RoutineDraft.make(for: repeated([at(19, 8, 40), at(20, 9, 10), at(21, 8, 55)]), botID: UUID(), calendar: calendar)
    #expect(weekdays.schedule == "0 8 * * 1-5" && weekdays.when == "every weekday at 8:00")
    #expect(weekdays.name == "Summarize my inbox" && weekdays.prompt == "Summarize my inbox?")
    let daily = RoutineDraft.make(for: repeated([at(20, 18, 5), at(21, 18, 20), at(24, 18, 40)]), botID: UUID(), calendar: calendar)
    #expect(daily.schedule == "0 18 * * *" && daily.when == "every day at 18:00", "a Saturday ask makes it every day")
    #expect(RoutineScheduleDraft(parsing: weekdays.schedule).preset == .weekdays && RoutineScheduleDraft(parsing: daily.schedule).preset == .daily,
            "the routine editor shows both in its plain picker")
}

@Test func quietHoursTheDailyCapAndTheSwitch() {
    let calendar = utcCalendar(), bot = UUID(), stems = AskText.stems("Summarize my inbox")
    func refusal(_ ledger: BotSuggestionLedger = .init(), enabled: Bool = true, now: Date) -> SuggestionPolicy.Refusal? {
        SuggestionPolicy.refusal(stems: stems, botID: bot, ledger: ledger, enabled: enabled, now: now, calendar: calendar)
    }
    #expect(refusal(now: at(21, 10)) == nil)
    #expect(refusal(now: at(21, 23)) == .quietHours && refusal(now: at(21, 7, 59)) == .quietHours)
    #expect(refusal(now: at(21, 8)) == nil && refusal(now: at(21, 22, 59)) == nil)
    #expect(refusal(enabled: false, now: at(21, 10)) == .off)
    #expect(refusal(BotSuggestionLedger(posted: [at(21, 8, 30), at(21, 9), at(21, 9, 30)]), now: at(21, 10)) == .dailyCap)
    #expect(refusal(BotSuggestionLedger(posted: [at(20, 8, 30), at(20, 9), at(20, 9, 30)]), now: at(21, 10)) == nil, "yesterday's do not count")
}

@Test func aNoIsForGoodAndSilenceWaitsAWeek() {
    let calendar = utcCalendar(), bot = UUID(), stems = AskText.stems("Summarize my inbox")
    func record(_ state: BotSuggestionRecord.State, askedAt: Date, botID: UUID? = nil) -> BotSuggestionRecord {
        BotSuggestionRecord(botID: botID ?? bot, stems: ["inbox", "summa"], example: "Summarize my inbox", askedAt: askedAt, state: state, messageID: UUID(),
                            draft: RoutineDraft(botID: bot, name: "Inbox", schedule: "0 9 * * *", prompt: "Summarize my inbox", weekdaysOnly: false, hour: 9))
    }
    func refusal(_ records: [BotSuggestionRecord], now: Date) -> SuggestionPolicy.Refusal? {
        SuggestionPolicy.refusal(stems: stems, botID: bot, ledger: BotSuggestionLedger(records: records), enabled: true, now: now, calendar: calendar)
    }
    #expect(refusal([record(.declined, askedAt: at(1, 10))], now: at(21, 10)) == .declined)
    #expect(refusal([record(.accepted, askedAt: at(15, 10))], now: at(21, 10)) == .accepted)
    #expect(refusal([record(.accepted, askedAt: at(1, 10))], now: at(21, 10)) == nil, "a yes pauses a week; the routine it made keeps it quiet after")
    #expect(refusal([record(.asked, askedAt: at(15, 10))], now: at(21, 10)) == .askedRecently, "6 days")
    #expect(refusal([record(.asked, askedAt: at(13, 10))], now: at(21, 10)) == nil, "8 days")
    #expect(refusal([record(.declined, askedAt: at(1, 10), botID: UUID())], now: at(21, 10)) == nil, "another bot's no is its own")
    var ledger = BotSuggestionLedger(records: [record(.declined, askedAt: at(1, 10)), record(.asked, askedAt: at(1, 10))], posted: [at(1, 10), at(21, 9)])
    ledger.prune(now: at(21, 10).addingTimeInterval(60 * 86_400))
    #expect(ledger.records.map(\.state) == [.declined] && ledger.posted.isEmpty, "a no is kept; an old unanswered one is not")
}

@Test func answersReadAsYesNoOrOther() {
    #expect(SuggestionAnswer.classify("No thanks") == .no)
    #expect(SuggestionAnswer.classify("nope") == .no)
    #expect(SuggestionAnswer.classify("I don't need that") == .no)
    #expect(SuggestionAnswer.classify("Yes, every weekday at 8:00") == .yes)
    #expect(SuggestionAnswer.classify("sure, but at 9") == .yes)
    #expect(SuggestionAnswer.classify("Please do") == .yes)
    #expect(SuggestionAnswer.classify("Different time") == .other)
    #expect(SuggestionAnswer.classify("maybe later") == .other)
    #expect(SuggestionAnswer.isAboutTheOffer("Make it 7:30 instead") && SuggestionAnswer.isAboutTheOffer("Different time"))
    #expect(!SuggestionAnswer.isAboutTheOffer("What's the weather in Warsaw?"))
}

@Test func theQuestionAndItsRepliesReadNaturally() {
    let week = repeated([at(19, 9, 30), at(20, 9, 30), at(21, 9, 30)], text: "Summarize my inbox.")
    let draft = RoutineDraft.make(for: week, botID: UUID(), calendar: utcCalendar())
    #expect(BotSuggestionCopy.question(week, draft: draft, now: at(21, 10))
            == "You've asked me for “Summarize my inbox” 3 times this week. Want me to run it every weekday at 9:00?")
    #expect(BotSuggestionCopy.replies(draft) == ["Yes, every weekday at 9:00", "Different time", "No thanks"])
    let fortnight = repeated([at(8, 9, 30), at(15, 9, 30), at(21, 9, 30)])
    #expect(BotSuggestionCopy.question(fortnight, draft: draft, now: at(21, 10)).contains("3 times in the last two weeks"))
    let lead = BotSuggestionCopy.lead(question: "Q?", draft: draft, timeZone: TimeZone(identifier: "Europe/Warsaw")!)
    #expect(lead.hasPrefix("(SwarmHub asked this in your chat for you: \"Q?\""))
    #expect(lead.contains("`0 9 * * 1-5`") && lead.contains("Europe/Warsaw") && lead.contains("Create nothing without my yes"))
}

@MainActor @Test func anyBotMessageCanCarrySuggestedReplies() throws {
    let message = ChatMessage(role: .assistant, content: "Which one?", presentation: .suggestion)
    #expect(message.suggestedReplies.isEmpty)
    message.suggestedReplies = ["A", " ", "B "]
    #expect(message.suggestedReplies == ["A", "B"])
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded.suggestedReplies == ["A", "B"] && decoded.presentation == .suggestion)
    message.suggestedReplies = []
    #expect(message.metadata[ChatMessage.suggestedRepliesKey] == nil)
}

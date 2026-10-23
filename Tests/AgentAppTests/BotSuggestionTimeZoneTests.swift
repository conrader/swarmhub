import Foundation
import Testing
@testable import AgentApp

// recsfix1 (live finding #13): the suggestion is offered in the Mac's time, but the box runs cron in its own zone (UTC on
// our boxes). The lead gives the bot the converted schedule and asks for `deliver 'local'`; after a yes, a routine on the
// converted schedule is the one agreed (no editor inviting a duplicate), and so is one a 0.6.5 lead had made on the
// Mac's hour. Only APIs that predate the fix are used here, so these also run against 0.6.5 as a control.
@MainActor struct BotSuggestionTimeZoneTests {
    private static let warsaw = TimeZone(identifier: "Europe/Warsaw")!

    private static func utc(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A job as a UTC box reports it (`next_run_at` in +00:00).
    private static func utcJob(_ id: String, schedule: String, name: String = "Inbox summary", prompt: String = "Summarize my inbox") -> [String: Any] {
        var job = jobPayload(id: id, name: name, schedule: schedule, prompt: prompt)
        job["next_run_at"] = "2026-10-22T09:00:00.000001+00:00"; job["created_at"] = "2026-10-21T10:00:00.000001+00:00"
        return job
    }

    /// A Hermes bot whose user is in Warsaw and asked for the inbox summary on Monday to Wednesday 19–21 October at 9:30
    /// UTC (11:30 in Warsaw, summer time), seen at `now`.
    private func warsawStore(now: Date, jobs: [[String: Any]] = []) -> (AppStore, Bot, FakeJobsServer) {
        let server = FakeJobsServer(); jobs.forEach(server.add)
        let (store, bot, _) = routinesStore(server)
        store.heartbeatTimeZone = Self.warsaw; store.now = { now }
        bot.messages = [19, 20, 21].flatMap { day in
            [ChatMessage(role: .user, content: "Summarize my inbox", createdAt: Self.utc(10, day, 9, 30)),
             ChatMessage(role: .assistant, content: "Here it is.", createdAt: Self.utc(10, day, 9, 31))]
        }
        return (store, bot, server)
    }

    /// The yes chip under the question, as the chat records it; the answer row carries the lead the bot reads first.
    private func yes(to row: ChatMessage, store: AppStore, bot: Bot) -> ChatMessage {
        let answer = ChatMessage(role: .user, content: BotSuggestionCopy.replies(store.suggestionLedger.records[0].draft)[0],
                                 metadata: [SuggestionKey.chip: "1", SuggestionKey.chipRow: row.id.uuidString])
        bot.messages.append(answer)
        store.noteSuggestionAnswer(answer, bot: bot, in: bot)
        return answer
    }

    @Test func theLeadGivesTheBoxsScheduleTheUsersTimeAndLocalDelivery() async throws {
        let (store, bot, _) = warsawStore(now: Self.utc(10, 21, 10))
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        #expect(row.content.hasSuffix("every weekday at 11:00?") && row.suggestedReplies[0] == "Yes, every weekday at 11:00", "the user sees their own time")
        let lead = try #require(yes(to: row, store: store, bot: bot).metadata[SuggestionKey.lead])
        #expect(lead.contains("schedule `0 9 * * 1-5`"), "11:00 in Warsaw (UTC+2) is 9:00 on the UTC box")
        #expect(!lead.contains("`0 11 * * 1-5`"))
        #expect(lead.contains("11:00 in my time zone Europe/Warsaw") && lead.contains("UTC"))
        #expect(lead.contains("deliver 'local'"), "kept on the box like the app's own routines, not sent to a home channel")
        #expect(store.suggestionLedger.records.first?.state == .accepted)
    }

    /// DST edge: offered on Saturday 24 October (summer time, UTC+2); summer time ends on Sunday 25 October, so the first
    /// weekday run, Monday 26 October 11:00, is UTC+1: 10:00 on the box, not the 9:00 today's offset gives.
    @Test func theConversionUsesTheOffsetOfTheRunsToComeAcrossADSTChange() async throws {
        let (store, bot, _) = warsawStore(now: Self.utc(10, 24, 12))
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        let lead = try #require(yes(to: row, store: store, bot: bot).metadata[SuggestionKey.lead])
        #expect(lead.contains("schedule `0 10 * * 1-5`") && lead.contains("11:00 in my time zone Europe/Warsaw"))
    }

    /// The bot made the routine on the converted schedule: that is the one agreed, so the editor (a duplicate) stays shut.
    @Test func aRoutineMadeOnTheConvertedScheduleIsTheOneAgreed() async throws {
        let (store, bot, server) = warsawStore(now: Self.utc(10, 21, 10))
        let row = try #require(await store.suggestRoutineIfRepeated(bot: bot))
        _ = yes(to: row, store: store, bot: bot)
        server.add(Self.utcJob("a1", schedule: "0 9 * * 1-5"))
        let reply = ChatMessage(role: .assistant, content: "Done: every weekday at 11:00 your time.")
        bot.messages.append(reply)
        #expect(await store.followThroughSuggestion(bot: bot, reply: reply))
        #expect(store.suggestions.editor == nil)
    }

    /// A routine already on the box at the converted time does the ask: no suggestion at all.
    @Test func anExistingConvertedRoutineIsNotOfferedAgain() async {
        let (store, bot, _) = warsawStore(now: Self.utc(10, 21, 10), jobs: [Self.utcJob("a1", schedule: "0 9 * * 1-5")])
        #expect(await store.suggestRoutineIfRepeated(bot: bot) == nil)
        #expect(!bot.messages.contains { $0.presentation == .suggestion })
    }

    /// A yes answered under 0.6.5: its lead gave the Mac's hour, so the bot may have made the routine on it (unconverted)
    /// or converted it itself; both are the one agreed. Another hour is not.
    @Test func aRoutineFromA065LeadIsRecognisedConvertedOrNot() async {
        func editorAfterYes(job schedule: String) async -> RoutineDraft? {
            let (store, bot, _) = warsawStore(now: Self.utc(10, 21, 10), jobs: [Self.utcJob("a1", schedule: schedule)])
            let draft = RoutineDraft(botID: bot.id, name: "Summarize my inbox", schedule: "0 11 * * 1-5", prompt: "Summarize my inbox", weekdaysOnly: true, hour: 11)
            let record = BotSuggestionRecord(botID: bot.id, stems: AskText.stems("Summarize my inbox").sorted(), example: "Summarize my inbox",
                                             askedAt: Self.utc(10, 21, 9), state: .accepted, messageID: UUID(), draft: draft)
            store.suggestionLedger = BotSuggestionLedger(records: [record])
            let reply = ChatMessage(role: .assistant, content: "Done.")
            bot.messages += [ChatMessage(role: .user, content: "Yes", metadata: [SuggestionKey.answers: record.id.uuidString, SuggestionKey.answer: "yes"]), reply]
            #expect(await store.followThroughSuggestion(bot: bot, reply: reply))
            return store.suggestions.editor
        }
        #expect(await editorAfterYes(job: "0 11 * * 1-5") == nil, "made on the Mac's hour, as the 0.6.5 lead said")
        #expect(await editorAfterYes(job: "0 9 * * mon-fri") == nil, "made on the converted hour")
        #expect(await editorAfterYes(job: "0 10 * * 1-5")?.schedule == "0 11 * * 1-5", "another hour: the editor opens")
    }
}

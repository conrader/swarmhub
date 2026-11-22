import Foundation
import Testing
@testable import AgentApp

// The files an imported bot's agent is handed (`GrokHandoff`): what is word for word, what a summary stands for,
// how a long message is cut, that nothing leaves unfiltered, and that the same archive gives the same bytes.

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func aShortConversationIsHandedOverWordForWord() {
    let lines = handoffConversation(exchanges: 5) + [
        handoffLine(11, "system", "Renamed from one name to another", channel: "event"),
        handoffLine(12, "user", "an instruction the person never saw", hidden: true),
        handoffLine(13, "assistant", "a line for another bot", channel: "agent", author: "Ada", to: "Bea"),
    ]
    let transcript = GrokHandoff.Transcript(lines)
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    #expect(plan.older.isEmpty && plan.recent.count == 11 && !plan.needsSummary)
    let rendered = GrokHandoff.render(transcript, plan: plan, summary: "a summary nobody needs", botName: "Ada")
    let handoff = text(rendered.handoff), full = text(rendered.full)
    for index in 1...5 { #expect(handoff.contains("question \(index) end") && handoff.contains("answer \(index) end"), "exchange \(index)") }
    #expect(handoff.contains("Ada → Bea") && handoff.contains("a line for another bot"), "what bots said to each other is part of it")
    #expect(!handoff.contains("Summary of the older part") && !handoff.contains("not summarised") && rendered.summary == nil, "nothing is older, so nothing is summarised")
    #expect(!handoff.contains("never saw") && !handoff.contains("Renamed from"), "hidden prompts and events are not in the recent part")
    #expect(full.contains("hidden prompt] an instruction the person never saw") && full.contains("event] Renamed from one name to another") && full.contains("bot to bot] a line for another bot"), "the full transcript has every line, tagged")
    #expect(rendered.handoff.count <= GrokHandoff.fileBytes && rendered.olderCount == 0 && rendered.recentCount == 11)
}

@Test func aLongConversationKeepsItsNewestPartFromAMessageOfThePerson() throws {
    let transcript = GrokHandoff.Transcript(handoffConversation(exchanges: 300, bytes: 400))
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    #expect(plan.needsSummary && plan.older.count + plan.recent.count == 600)
    let first = try #require(plan.recent.first)
    #expect(first.role == "user" && first.channel == "chat", "the recent part starts where the person spoke")
    #expect(plan.recent.count >= 4 && plan.recent.last?.seq == 600 && plan.older.last?.seq == first.seq - 1)
    let without = GrokHandoff.render(transcript, plan: plan, summary: nil, botName: "Ada")
    let bare = text(without.handoff)
    #expect(bare.contains("The older part is not summarised here") && bare.contains("question 300 end") && bare.contains("answer 299 end"))
    #expect(!bare.contains("question 1 end") && text(without.full).contains("question 1 end"), "the older part is only in the full transcript")
    #expect(without.handoff.count <= GrokHandoff.fileBytes && without.summary == nil)
    // A summary longer than its room is cut to it, and the file still fits.
    let long = String(repeating: "They agreed to ship on Friday. ", count: 600)
    let with = GrokHandoff.render(transcript, plan: plan, summary: long, botName: "Ada")
    #expect(text(with.handoff).contains("## Summary of the older part (\(plan.older.count) messages, #1 to #\(first.seq - 1))"))
    #expect((with.summary?.utf8.count ?? 0) <= GrokHandoff.summaryBytes && with.summary?.hasPrefix("They agreed to ship on Friday.") == true)
    #expect(with.handoff.count <= GrokHandoff.fileBytes && with.olderCount == plan.older.count && with.recentCount == plan.recent.count)
}

@Test func anOversizedMessageIsCutInTheMiddleWithAPointerToTheFullTranscript() {
    let body = "the very start of the long answer " + String(repeating: "word ", count: 6_000) + "the middle of the long answer " + String(repeating: "word ", count: 6_000) + "the very end of the long answer"
    let lines = handoffConversation(exchanges: 300, bytes: 400) + [handoffLine(601, "user", "write it all out"), handoffLine(602, "assistant", body, author: "Ada")]
    let transcript = GrokHandoff.Transcript(lines)
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    let rendered = GrokHandoff.render(transcript, plan: plan, summary: nil, botName: "Ada")
    let handoff = text(rendered.handoff)
    #expect(plan.recent.last?.seq == 602 && plan.recent.contains { $0.seq == 601 })
    #expect(handoff.contains("bytes left out here. The whole message is #602 in grok-history-full.md"))
    #expect(handoff.contains("the very start of the long answer") && handoff.contains("the very end of the long answer") && !handoff.contains("the middle of the long answer"))
    #expect(text(rendered.full).contains("the middle of the long answer"), "the full transcript has the whole message")
    #expect(rendered.handoff.count <= GrokHandoff.fileBytes)
    // The last two exchanges are there even when all of their messages are long: each is cut to an equal share.
    // (Two exchanges of one question and two answers each, every message about 20,000 bytes.)
    let longOnes = (1...6).map { number -> ArchivedMessage in
        let role = number == 1 || number == 4 ? "user" : "assistant"
        return handoffLine(Int64(700 + number), role, "start \(number) " + String(repeating: "word ", count: 4_000) + "end \(number)")
    }
    let heavy = GrokHandoff.Transcript(handoffConversation(exchanges: 300, bytes: 400) + longOnes)
    let heavyPlan = GrokHandoff.plan(heavy, botName: "Ada")
    #expect(heavyPlan.recent.map(\.seq) == [701, 702, 703, 704, 705, 706] && heavyPlan.messageLimit < GrokHandoff.messageBytes)
    let heavyText = text(GrokHandoff.render(heavy, plan: heavyPlan, summary: nil, botName: "Ada").handoff)
    #expect(heavyText.utf8.count <= GrokHandoff.fileBytes && heavyText.contains("start 1 ") && heavyText.contains("end 6"))
}

@Test func aSecretAnOlderFilterLeftInTheArchiveNeverLeaves() throws {
    let secret = "synthetic-secret-value-7"
    // Lines as a file written under an older filter would hold them: built directly, never through the importer.
    var lines = handoffConversation(exchanges: 300, bytes: 400)
    lines[10] = handoffLine(lines[10].seq, "user", "for the old box use password: \(secret) please")
    lines.append(handoffLine(601, "user", "and the new one, password: \(secret) too"))
    lines.append(handoffLine(602, "assistant", "noted", author: "Ada"))
    let transcript = GrokHandoff.Transcript(lines)
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    #expect(plan.older.contains { $0.seq == lines[10].seq } && plan.recent.contains { $0.seq == 601 })
    let rendered = GrokHandoff.render(transcript, plan: plan, summary: "The person gave a password: \(secret) for the box.", botName: "Ada")
    let parts = try #require(GrokHandoff.parts(of: plan.older, botName: "Ada"))
    let handoff = GrokHandoff.package(rendered, archiveID: UUID())
    var leaving: [String] = [text(rendered.handoff), text(rendered.full), rendered.summary ?? "",
                             handoff.note(bytes: 8_000, withFiles: true), handoff.note(bytes: 8_000, withFiles: false)]
    leaving += rendered.lastExchanges
    leaving += parts.texts
    leaving += handoff.files.map { text($0.data) }
    for (index, piece) in leaving.enumerated() { #expect(!piece.contains(secret), "the secret is in piece \(index)") }
    #expect(text(rendered.handoff).contains(GrokRedactor.marker) && text(rendered.full).contains(GrokRedactor.marker) && rendered.summary?.contains(GrokRedactor.marker) == true)
    // A saved summary goes through the filter when it is stored and again when it is loaded.
    #expect(!GrokHandoffCache(summary: "password: \(secret)", from: 1, through: 2, messages: 2, template: "", model: "", madeAt: Date(timeIntervalSince1970: 0)).summary.contains(secret))
}

@Test func theSameArchiveGivesTheSameBytesAndRevision() {
    let lines = handoffConversation(exchanges: 300, bytes: 400)
    func rendered(_ lines: [ArchivedMessage]) -> GrokHandoff.Rendered {
        let transcript = GrokHandoff.Transcript(lines)
        return GrokHandoff.render(transcript, plan: GrokHandoff.plan(transcript, botName: "Ada"), summary: "A summary.", botName: "Ada")
    }
    let once = rendered(lines), again = rendered(lines)
    #expect(once == again && once.handoff == again.handoff && once.full == again.full && once.revision == again.revision)
    #expect(once.revision == "600-600")
    let grown = rendered(lines + [handoffLine(601, "user", "one more")])
    #expect(grown.revision == "601-601" && grown.revision != once.revision && grown.handoff != once.handoff)
    let id = UUID()
    let handoff = GrokHandoff.package(once, archiveID: id)
    #expect(handoff.lead == "[SwarmHub handoff \(id.uuidString.lowercased().prefix(8)) " && handoff.marker == handoff.lead + "r600-600]")
    #expect(handoff.files.map(\.name) == ["grok-handoff.md", "grok-history-full.md"] && handoff.files[0].data == once.handoff && handoff.files[1].data == once.full)
    #expect(GrokHandoff.package(grown, archiveID: id).lead == handoff.lead, "a later revision is found by the same lead")
}

@Test func aSavedSummaryStaysGoodWhileFewLinesWereAdded() throws {
    let lines = handoffConversation(exchanges: 300, bytes: 400)
    let before = GrokHandoff.plan(GrokHandoff.Transcript(lines), botName: "Ada")
    let through = try #require(before.older.last?.seq)
    let same = GrokHandoff.plan(GrokHandoff.Transcript(lines), botName: "Ada", summarisedThrough: through)
    #expect(same.covered && !same.needsSummary && same.older == before.older && same.recent == before.recent)
    // Two more exchanges: the lines the summary does not stand for join the recent part.
    let few = (601...604).map { handoffLine(Int64($0), $0 % 2 == 1 ? "user" : "assistant", "a later line \($0)") }
    let little = GrokHandoff.plan(GrokHandoff.Transcript(lines + few), botName: "Ada", summarisedThrough: through)
    #expect(little.covered && little.older.last?.seq == through && little.recent.first?.seq == through + 1 && little.recent.last?.seq == 604)
    // Many more: the summary no longer covers the older part, so a new one is needed.
    let many = GrokHandoff.plan(GrokHandoff.Transcript(lines + handoffConversation(exchanges: 400, bytes: 400).suffix(200)), botName: "Ada", summarisedThrough: through)
    #expect(!many.covered && many.needsSummary)
    // With no saved summary the older part always needs one.
    #expect(before.needsSummary && !before.covered)
}

@Test func theNoteFitsItsBytesAndCarriesAnExcerpt() {
    let transcript = GrokHandoff.Transcript(handoffConversation(exchanges: 300, bytes: 400))
    let plan = GrokHandoff.plan(transcript, botName: "Ada")
    let summary = String(repeating: "They agreed to ship on Friday. ", count: 600)
    let summarised = GrokHandoff.package(GrokHandoff.render(transcript, plan: plan, summary: summary, botName: "Ada"), archiveID: UUID())
    let plain = GrokHandoff.package(GrokHandoff.render(transcript, plan: plan, summary: nil, botName: "Ada"), archiveID: UUID())
    #expect(summarised.olderMessages == plan.older.count && summarised.recentMessages == plan.recent.count && summarised.summary != nil && plain.summary == nil)
    for bytes in [5_200, 8_000] {
        let note = summarised.note(bytes: bytes, withFiles: true)
        #expect(note.utf8.count <= bytes && note.utf8.count > bytes - 200, "the excerpt uses the room it has: \(note.utf8.count) of \(bytes)")
        #expect(note.hasPrefix(summarised.marker) && note.contains("grok-handoff.md") && note.contains("grok-history-full.md"))
        #expect(note.contains("A summary, in case you cannot open the files:") && note.contains("They agreed to ship on Friday."))
        let last = plain.note(bytes: bytes, withFiles: true)
        #expect(last.utf8.count <= bytes && last.hasPrefix(plain.marker) && last.contains("The last messages, in case you cannot open the files:"))
        #expect(last.contains("question 300 end") && last.contains("answer 300 end") && last.contains("question 299 end"), "the last two exchanges")
    }
    let alone = summarised.note(bytes: 5_200, withFiles: false)
    #expect(alone.utf8.count <= 5_200 && alone.contains("could not take the files") && !alone.contains("grok-handoff.md") && alone.contains("They agreed to ship on Friday."))
    // Whatever instructions a bot has, the note fits beside them in a first task that carries files.
    let persona = String(repeating: "Be kind. ", count: 2_000)
    let own = HerdrClient.plain(persona, bytes: HerdrClient.instructionsBytes)
    let room = HerdrClient.firstMessageBudget(instructions: own, hasFiles: true)
    #expect(room > 4_000 && HerdrClient.firstTask(summarised.note(bytes: room, withFiles: true), instructions: own).utf8.count <= 12 * 1024)
}

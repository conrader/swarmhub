import Foundation
import Testing
@testable import AgentApp

/// Where the steps row of a reply goes: between two blocks of its text, never inside a paragraph, a list or a code
/// block, for a reply that is still streaming and for one that was saved.
struct ReplyLayoutTests {
    private func activity(_ offsets: [Int?], running: Bool = false) -> ToolActivity {
        var activity = ToolActivity()
        let start = Date(timeIntervalSince1970: 1_000)
        for (index, offset) in offsets.enumerated() {
            activity.steps.append(ToolStep(name: "bash", preview: nil, startedAt: start + Double(index), finishedAt: running ? nil : start + Double(index) + 1, callID: "\(index)", textOffset: offset))
        }
        activity.total = offsets.count
        return activity
    }

    private func offset(of marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { Issue.record("no \(marker) in the text"); return 0 }
        return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    }

    private func texts(_ segments: [ReplySegment]?) -> [String] {
        (segments ?? []).compactMap { if case .text(let text) = $0 { text.trimmingCharacters(in: .whitespacesAndNewlines) } else { nil } }
    }

    @Test func stepsThatStartedInsideAWordGoAfterItsParagraph() {
        // The reply of the report: four steps began while "registration" was half written.
        let text = "I registered the server. Next I will run the client to check that registration succeeds and the MCP responds.\n\nIt does: the client listed three tools."
        let cut = offset(of: "on succeeds", in: text)
        let segments = ReplyLayout.segments(content: text, activity: activity([cut, cut, cut, cut]))
        #expect(segments == [.text("I registered the server. Next I will run the client to check that registration succeeds and the MCP responds."), .steps(0..<4),
                             .text("\n\nIt does: the client listed three tools.")])
        // No piece of text starts or ends inside a word of the original.
        #expect(texts(segments) == text.components(separatedBy: "\n\n"))
    }

    @Test func stepsBetweenParagraphsStayWhereTheyHappened() {
        let text = "First I read the file.\n\nThen I ran the tests.\n\nAll green."
        let first = offset(of: "\n\nThen", in: text), second = offset(of: "All green", in: text)
        let segments = ReplyLayout.segments(content: text, activity: activity([first, second]))
        #expect(texts(segments) == ["First I read the file.", "Then I ran the tests.", "All green."])
        #expect(segments?.filter { if case .steps = $0 { true } else { false } } == [.steps(0..<1), .steps(1..<2)])
    }

    @Test func stepsInsideOneParagraphJoinIntoOneRowAfterIt() {
        let text = "I will look at three files and then say what I found.\n\nHere is what I found."
        let offsets = ["look", "three", "then say"].map { offset(of: $0, in: text) }
        let segments = ReplyLayout.segments(content: text, activity: activity(offsets))
        #expect(segments == [.text("I will look at three files and then say what I found."), .steps(0..<3), .text("\n\nHere is what I found.")])
    }

    @Test func aListOrACodeBlockIsNeverDivided() {
        let list = "Steps:\n- one\n- two\n- three\n\nDone."
        #expect(texts(ReplyLayout.segments(content: list, activity: activity([offset(of: "- two", in: list)]))) == ["Steps:\n- one\n- two\n- three", "Done."])
        // A blank line inside a fence is not a place to divide the text.
        let code = "Run this:\n\n```sh\nmake\n\nmake test\n```\n\nThat is all."
        let inside = offset(of: "make test", in: code) - 1
        #expect(texts(ReplyLayout.segments(content: code, activity: activity([inside]))) == ["Run this:\n\n```sh\nmake\n\nmake test\n```", "That is all."])
    }

    @Test func aStreamingReplyKeepsItsRowUnderTheParagraphBeingWritten() {
        // The step arrives at the end of the text so far; the same paragraph then goes on, and a new one starts.
        let soFar = "I will check that registrati"
        let offsets = [soFar.utf16.count]
        #expect(ReplyLayout.segments(content: soFar, activity: activity(offsets, running: true)) == [.text(soFar), .steps(0..<1)])
        let later = soFar + "on succeeds."
        #expect(ReplyLayout.segments(content: later, activity: activity(offsets, running: true)) == [.text(later), .steps(0..<1)])
        let next = later + "\n\nIt does."
        #expect(ReplyLayout.segments(content: next, activity: activity(offsets)) == [.text(later), .steps(0..<1), .text("\n\nIt does.")])
        // A fence that is still open while it streams is not divided either.
        let open = "Here:\n\n```\nline one\n\nline"
        #expect(ReplyLayout.segments(content: open, activity: activity([offset(of: "line one", in: open) + 3], running: true)) == [.text(open), .steps(0..<1)])
    }

    @Test func stepsBeforeAnyTextAndAfterAllOfItKeepTheirPlace() {
        let text = "Found it.\n\nThe key was missing."
        #expect(ReplyLayout.segments(content: text, activity: activity([0, text.utf16.count])) == [.steps(0..<1), .text(text), .steps(1..<2)])
        // An offset beyond the text (the text was replaced by a shorter one) is the end of it.
        #expect(ReplyLayout.segments(content: "Short.", activity: activity([400])) == [.text("Short."), .steps(0..<1)])
    }

    @Test func aSavedReplyIsLaidOutByTheSameRule() throws {
        // A message as an older version stored it: the offset is inside a word.
        let text = "Checking the registrati" + "on now.\n\nRegistered."
        let message = ChatMessage(role: .assistant, content: text)
        message.activity = activity([23])
        let stored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(stored.activity?.steps.first?.textOffset == 23)
        #expect(ReplyLayout.segments(content: stored.content, activity: stored.activity) == [.text("Checking the registration now."), .steps(0..<1), .text("\n\nRegistered.")])
        // The conclusion (the sidebar's line, Copy reply) is the last whole paragraph.
        #expect(stored.finalText == "Registered.")
    }

    @Test func textInOtherScriptsIsCountedInItsOwnUnits() {
        // Offsets are UTF-16: an emoji is two of them, and a row must not land inside one.
        let text = "Zażółć 👩‍💻 gęślą jaźń.\n\nGotowe."
        let cut = offset(of: "gęślą", in: text) - 3
        #expect(texts(ReplyLayout.segments(content: text, activity: activity([cut]))) == ["Zażółć 👩‍💻 gęślą jaźń.", "Gotowe."])
    }

    @Test func repliesWithoutOrderedStepsKeepOneRowUnderTheText() {
        #expect(ReplyLayout.segments(content: "Text.", activity: nil) == nil)
        #expect(ReplyLayout.segments(content: "Text.", activity: activity([nil])) == nil)
    }

    // MARK: Cards in a reply with steps

    @Test @MainActor func aQuestionAfterStepsIsAnsweredAndStaysMarked() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in TestBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Infra", backend: .herdr)
        store.bots = [bot]; store.selectedBot = bot
        let text = "I looked at the build box.\n\nIt can publish in two ways.\n\n```choices\nWhich one?\n- After every build\n- Once a night\n```\n\nTell me when you have decided."
        let reply = ChatMessage(role: .assistant, content: text, turnState: .finished)
        reply.activity = activity([offset(of: "\n\nIt can", in: text), offset(of: "ways.", in: text)])
        bot.messages = [ChatMessage(role: .user, content: "Publish the tokens."), reply]
        let segments = try #require(ReplyLayout.segments(content: text, activity: reply.activity))
        // Two rows of steps divide the prose before the card: three pieces of prose where the whole reply has one.
        #expect(segments.count == 5)
        let indexes = ReplyLayout.blockIndexes(segments, content: text)
        let whole = ChatCardParser.parse(text)
        let place = try #require(whole.firstIndex { if case .choices = $0 { true } else { false } })
        #expect(indexes.flatMap { $0 }.filter { $0 >= 0 } == [place], "the card has the place it has in the whole reply")
        // The pick the card sends is accepted and remembered under that place, where the card looks for it.
        #expect(store.performCardAction(target: .bot(botID: bot.id), sourceID: reply.id, index: place, expected: whole[place], choice: "Once a night"))
        #expect(reply.metadata["picked.\(place)"] == "Once a night" && store.errorMessage == nil)
        // A second card keeps its own place, also behind another row of steps.
        let two = text + "\n\n```choices\nAnd when?\n- Now\n- Tonight\n```"
        let more = activity([offset(of: "\n\nIt can", in: two), offset(of: "Tell me", in: two)])
        let both = ReplyLayout.blockIndexes(try #require(ReplyLayout.segments(content: two, activity: more)), content: two).flatMap { $0 }.filter { $0 >= 0 }
        let cards = ChatCardParser.parse(two).enumerated().filter { if case .choices = $0.element { true } else { false } }.map(\.offset)
        #expect(both == cards && cards.count == 2)
    }
}


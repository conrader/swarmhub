import Foundation
import Testing
@testable import AgentApp

private let ids = (0..<6).map { _ in UUID() }
private let utc = TimeZone(identifier: "UTC")!
private func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60) } // 2026-09-21 14:13 UTC

struct MessageSelectionTests {
    // ⌘-click toggles a row and makes it the anchor; ⇧-click runs from the anchor.
    @Test func commandClickTogglesRowsAndSetsTheAnchor() {
        var selection = MessageSelectionState()
        #expect(selection.isEmpty && selection.anchor == nil)
        selection.toggle(ids[1]); selection.toggle(ids[4])
        #expect(selection.selected == [ids[1], ids[4]] && selection.anchor == ids[4])
        selection.toggle(ids[1]); #expect(selection.selected == [ids[4]] && selection.anchor == ids[4], "deselecting another row keeps the anchor")
        selection.toggle(ids[4]); #expect(selection.isEmpty && selection.anchor == nil)
    }

    @Test func shiftClickSelectsTheRunFromTheAnchorAndReplacesThePreviousRun() {
        var selection = MessageSelectionState()
        selection.toggle(ids[2])
        selection.extend(to: ids[4], order: ids); #expect(selection.selected == Set(ids[2...4]))
        selection.extend(to: ids[0], order: ids); #expect(selection.selected == Set(ids[0...2]), "upwards, and the earlier run is replaced")
        selection.extend(to: ids[2], order: ids); #expect(selection.selected == [ids[2]] && selection.anchor == ids[2])
    }

    @Test func shiftClickKeepsCommandPickedRowsOutsideTheRun() {
        var selection = MessageSelectionState()
        selection.toggle(ids[0]); selection.toggle(ids[3])
        selection.extend(to: ids[5], order: ids)
        #expect(selection.selected == [ids[0], ids[3], ids[4], ids[5]])
        selection.toggle(ids[1]); selection.extend(to: ids[2], order: ids)
        #expect(selection.selected == [ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]], "a ⌘-click commits the run, a new run starts at the new anchor")
    }

    @Test func shiftClickWithoutAnAnchorPicksTheClickedRowAndClearEmpties() {
        var selection = MessageSelectionState()
        selection.extend(to: ids[3], order: ids); #expect(selection.selected == [ids[3]] && selection.anchor == ids[3])
        selection.extend(to: ids[5], order: ids); #expect(selection.selected == Set(ids[3...5]))
        selection.clear(); #expect(selection == MessageSelectionState())
        selection.toggle(ids[1]); selection.extend(to: UUID(), order: ids)
        #expect(selection.selected.count == 2, "a row not in the transcript order is added without a run")
    }

    @Test func copiedTextIsChronologicalWithAuthorAndTimestamp() {
        let rows = [CopiedMessage(author: "Atlas", date: at(2), text: "Second"),
                    CopiedMessage(author: "Konrad", date: at(0), text: "First\nline two"),
                    CopiedMessage(author: "SwarmHub", date: at(2), text: "Same minute, later in the transcript")]
        #expect(MessageCopy.text(rows, timeZone: utc) == """
        Konrad · 2026-09-21 14:13
        First
        line two

        Atlas · 2026-09-21 14:15
        Second

        SwarmHub · 2026-09-21 14:15
        Same minute, later in the transcript
        """)
        #expect(MessageCopy.text([], timeZone: utc).isEmpty)
        #expect(MessageCopy.text([CopiedMessage(author: "Atlas", date: at(0), text: "")], timeZone: utc) == "Atlas · 2026-09-21 14:13")
    }

    @Test func copiedBodyIsTrimmedAndListsAttachments() {
        #expect(MessageCopy.body("  hello \n\n") == "hello")
        #expect(MessageCopy.body("See this", attachmentNames: ["plan.pdf", "shot.png"]) == "See this\n[Attachment: plan.pdf]\n[Attachment: shot.png]")
        #expect(MessageCopy.body(" ", attachmentNames: ["shot.png"]) == "[Attachment: shot.png]")
        #expect(MessageCopy.menuTitle(count: 1) == "Copy Message" && MessageCopy.menuTitle(count: 3) == "Copy 3 Messages")
    }

    @MainActor @Test func copiedMessagesNameTheUserBotsAndSwarmHub() {
        let defaults = isolatedDefaults(); defaults.set("Konrad", forKey: UserIdentity.key)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
        let mira = Bot(name: "Mira", backend: .hermes, hermesProfile: "mira"); store.bots = [mira]
        #expect(store.copyAuthor(ChatMessage(role: .user, content: "Hi"), botName: "Atlas") == "Konrad")
        #expect(store.copyAuthor(ChatMessage(role: .assistant, content: "Hello"), botName: "Atlas") == "Atlas")
        #expect(store.copyAuthor(ChatMessage(role: .assistant, content: "Hello", authorID: mira.id), botName: "Team") == "Mira", "a group reply names its member")
        #expect(store.copyAuthor(ChatMessage(role: .assistant, content: "Hello", authorID: UUID()), botName: "Team") == "Removed bot")
        #expect(store.copyAuthor(ChatMessage(role: .system, content: "Stopped"), botName: "Atlas") == "SwarmHub")
        let arrival = ChatMessage(role: .system, content: "Mira wrote", presentation: .botMessage, metadata: [BotMessageKey.from: "mira"])
        #expect(store.copyAuthor(arrival, botName: "Atlas") == "Mira", "a bot-to-bot line names its sender")

        let reply = ChatMessage(role: .assistant, content: "Here it is.", createdAt: at(1),
                                attachments: [ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 4)])
        #expect(store.copiedMessage(reply, botName: "Atlas") == CopiedMessage(author: "Atlas", date: at(1), text: "Here it is.\n[Attachment: notes.txt]"))
    }

    @MainActor @Test func selectionCopiesOnlyPickedRowsStillShownOldestFirst() {
        let messages = [ChatMessage(role: .user, content: "Question", createdAt: at(0)), ChatMessage(role: .assistant, content: "Answer", createdAt: at(1)),
                        ChatMessage(role: .user, content: "Thanks", createdAt: at(3)), ChatMessage(role: .assistant, content: "Arrival", createdAt: at(2))]
        let selection = MessageSelection()
        let describe: (ChatMessage) -> CopiedMessage = { CopiedMessage(author: $0.role == .user ? "Konrad" : "Atlas", date: $0.createdAt, text: $0.content) }
        selection.show(rows: messages, describe: describe)
        #expect(selection.count == 0 && selection.copiedText.isEmpty)
        selection.toggle(messages[2].id); selection.toggle(messages[0].id); selection.toggle(messages[3].id)
        #expect(selection.isSelected(messages[3].id) && !selection.isSelected(messages[1].id) && selection.count == 3)
        let text = selection.copiedText
        #expect(text.components(separatedBy: "\n\n").map { $0.components(separatedBy: "\n").last ?? "" } == ["Question", "Arrival", "Thanks"])
        #expect(text.hasPrefix("Konrad · ") && !text.contains("Answer"))

        selection.extend(to: messages[1].id); #expect(selection.count == 4, "the run from the anchor (Arrival) up to Answer joins the ⌘-picked rows")
        selection.show(rows: Array(messages.prefix(2)), describe: describe)
        #expect(selection.count == 2 && !selection.copiedText.contains("Thanks"), "a row no longer shown is not copied")
        selection.clear(); #expect(selection.count == 0 && selection.state.isEmpty)
    }
}

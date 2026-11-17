import Foundation
import Testing
@testable import AgentApp

// "About you" and the main bot's first conversation.

@Test func aboutYouAdditionsAreReadFromAReplyAndKeptAsLines() {
    let reply = "Noted.\n\n```swarmhub\n{\"op\":\"about_you\",\"add\":[\" Goes by Sam. \",\"goes by sam.\",\"Keeps a bakery's books.\"]}\n```"
    #expect(HerdrAboutYou.additions(in: reply) == ["Goes by Sam.", "Keeps a bakery's books."], "one line each, none twice")
    #expect(HerdrAboutYou.additions(in: "```swarmhub\n{\"op\":\"about_you\",\"add\":\"Line one\\nline two\"}\n```") == ["Line one line two"])
    #expect(HerdrAboutYou.additions(in: "no block").isEmpty && HerdrAboutYou.additions(in: "```swarmhub\n{\"op\":\"about_you\",\"add\":\"Half").isEmpty
        && HerdrAboutYou.additions(in: "```swarmhub\n{\"op\":\"create_bot\",\"name\":\"X\"}\n```").isEmpty, "nothing from plain text, an unfinished block or another op")
    #expect(HerdrAboutYou.adding("Likes short answers.", to: "Goes by Sam.") == "Goes by Sam.\nLikes short answers." && HerdrAboutYou.adding("goes by sam.", to: "Goes by Sam.") == "Goes by Sam.")
    #expect(HerdrAboutYou.adding("x", to: String(repeating: "a", count: HerdrAboutYou.limit)) == nil, "a full text takes no more")
    #expect(HerdrAboutYou.note("") == "" && HerdrAboutYou.note(" Goes by Sam. ") == HerdrAboutYou.lead + "\nGoes by Sam.")
    #expect(HerdrAboutYou.additions(in: HerdrAboutYou.how).count == 1 && HerdrAboutYou.how.contains(HerdrAboutYou.marker), "the how-to's own example parses")
}

@Test func theKickOffNoteAsksForAGreetingAndOneQuestionAtATime() {
    let note = HerdrIntro.note(name: "Robin", projects: "Settings → Servers → Projects")
    #expect(note.hasPrefix(HerdrIntro.lead) && note.contains("Robin") && note.contains("Settings → Servers → Projects") && note.contains("ONE per reply") && note.contains("skip"))
    #expect(note.utf8.count < 2_800, "it fits beside full instructions in a first task (\(note.utf8.count) bytes)")
    #expect(HerdrAboutYou.additions(in: note).isEmpty && HerdrBotRequest.requests(in: note).isEmpty, "the note itself asks the app for nothing")
    let again = HerdrIntro.note(name: "Robin", about: "Goes by Sam.", again: true)
    #expect(again.contains("Goes by Sam.") && !again.contains("just finished setting you up") && again.contains("cannot add project servers"))
}

@MainActor @Test func everyBotReadsAboutYouAndOnlyTheMainBotProposesAdditions() throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let main = Bot(name: "Robin", backend: .herdr), other = Bot(name: "Infra", backend: .herdr); main.canManageBots = true
    store.bots = [main, other]
    store.setHerdrToken("t", for: store.herdrServers[0])
    #expect(try store.herdrBackend(for: other).aboutYou == "" && store.herdrBackend(for: main).aboutHow == HerdrAboutYou.how && store.herdrBackend(for: other).aboutHow == nil)
    store.aboutYou = "  Goes by Sam.  "
    #expect(store.aboutYou == "Goes by Sam.")
    let told = try store.herdrBackend(for: other)
    #expect(told.aboutYou == HerdrAboutYou.note("Goes by Sam.") && told.launchInstructions?.contains("Goes by Sam.") == true, "a new agent of any bot reads it")
    #expect(told.rosters.contains { $0.lead == HerdrAboutYou.lead }, "and a running agent is told when it changed")
    // The main bot proposes; nothing is saved until the person says so.
    main.messages = [ChatMessage(role: .user, content: "Call me Sam, I keep a bakery's books."),
                     ChatMessage(role: .assistant, content: "Noted.\n\n```swarmhub\n{\"op\":\"about_you\",\"add\":[\"Goes by Sam.\",\"Keeps a bakery's books.\"]}\n```")]
    let pending = store.pendingAboutYou(for: main)
    #expect(pending.map(\.text) == ["Keeps a bakery's books."], "what the text already says is not offered again")
    #expect(store.aboutYou == "Goes by Sam.")
    #expect(store.acceptAboutYou(pending[0]) && store.aboutYou == "Goes by Sam.\nKeeps a bakery's books." && store.pendingAboutYou(for: main).isEmpty)
    other.messages = main.messages
    #expect(store.pendingAboutYou(for: other).isEmpty, "another bot's block proposes nothing")
    main.messages.append(ChatMessage(role: .assistant, content: "Also.\n\n```swarmhub\n{\"op\":\"about_you\",\"add\":\"Likes tea.\"}\n```"))
    let next = store.pendingAboutYou(for: main)
    store.dismissAboutYou(next[0])
    #expect(next.map(\.text) == ["Likes tea."] && store.pendingAboutYou(for: main).isEmpty && !store.aboutYou.contains("tea"), "Don't save keeps it out, and it is not offered again")
}

@MainActor @Test func theIntroductionIsSentOnceAndOfferedQuietlyToAMainBotFromBefore() throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in MockBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let main = Bot(name: "Robin", backend: .herdr), other = Bot(name: "Infra", backend: .herdr); main.canManageBots = true
    store.bots = [main, other]
    #expect(store.offersHerdrIntro(main) && !store.offersHerdrIntro(other), "a main bot that never introduced itself offers to; no other bot does")
    #expect(!store.startHerdrIntro(for: other) && other.messages.isEmpty, "only a main bot is asked")
    store.dismissHerdrIntro(main)
    #expect(!store.offersHerdrIntro(main) && main.messages.isEmpty, "Not now puts the offer away and sends nothing")
    #expect(store.startHerdrIntro(for: main, again: true), "the menu still asks for it")
    let sent = try #require(main.messages.first)
    #expect(sent.role == .user && sent.metadata[HerdrIntro.Key.kind] == HerdrIntro.again && sent.content.hasPrefix(HerdrIntro.lead) && store.isAppWritten(sent))
    #expect(store.herdrIntroState(main) == AppStore.introStarted && !store.offersHerdrIntro(main))
    // The chat and the sidebar never show the note as the person's words.
    #expect(SidebarFragment.text(messages: [sent], draft: nil, isWorking: false, archiveNewest: nil) == "", "the sidebar shows nothing of the note")
    #expect(HerdrIntro.caption(bot: "Robin", again: false).contains("Robin") && ManageBotsAction.getToKnowMe.request == nil && ManageBotsAction.newBot.request != nil)
}

@Test func aProposedAdditionReadsAsOnePlainLineUnderTheReply() {
    #expect(SwarmhubSummary.lines(in: "Noted.\n\n```swarmhub\n{\"op\":\"about_you\",\"add\":\"x\"}\n```").map(\.summary) == ["Noted something about you"])
}

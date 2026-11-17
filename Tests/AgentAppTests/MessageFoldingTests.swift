import Foundation
import Testing
@testable import AgentApp

/// Messages between bots: folded when drawn, one clean line while folded, the same on both sides of an exchange,
/// and in the colour of the bot whose words they are.
@MainActor struct MessageFoldingTests {
    private func makeStore() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in TestBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    // MARK: The fold

    @Test func everyCardStartsFoldedAndAClickTurnsItOver() {
        let first = UUID(), second = UUID()
        var folds = FoldState()
        #expect(!folds.isOpen(first) && !folds.isOpen(second))
        folds.toggle(first)
        #expect(folds.isOpen(first) && !folds.isOpen(second), "unfolding one card leaves the others folded")
        folds.toggle(first)
        #expect(!folds.isOpen(first), "a second click folds it again")
    }

    @Test func whatIsUnfoldedIsKeptForTheChatOnScreenOnly() {
        let card = UUID()
        let chat = ChatFolds()
        chat.state.toggle(card)
        #expect(chat.state.isOpen(card))
        // Another chat is shown, or this one opens again: every card is folded.
        chat.state.foldAll()
        #expect(!chat.state.isOpen(card))
        #expect(!ChatFolds().state.isOpen(card), "nothing is saved: a new chat view starts folded")
        #expect(ChatFolds(open: [card]).state.isOpen(card), "a render can start with a card unfolded")
    }

    // MARK: The folded line

    @Test func theFoldedLineIsTheFirstLineOrSentence() {
        #expect(HerdrPassedOn.firstSentence(of: "Can you publish the tokens?\n\nNo hurry.") == "Can you publish the tokens?")
        let long = "Please set up the registry on the build box and tell me the version. Then write it down in the notes, and do not restart anything while a build is running."
        #expect(HerdrPassedOn.firstSentence(of: long) == "Please set up the registry on the build box and tell me the version.")
        // The marks that open a heading, a list item or a quote are not part of the line.
        #expect(HerdrPassedOn.firstSentence(of: "## Plan\n- one") == "Plan")
        #expect(HerdrPassedOn.firstSentence(of: "\n\n- **First** check `tools.lock`") == "First check tools.lock")
        #expect(HerdrPassedOn.firstSentence(of: "1. Install the server") == "Install the server")
        #expect(HerdrPassedOn.firstSentence(of: " \n ") == "")
        // A full stop inside a number or an abbreviation near the start does not end the sentence there.
        #expect(HerdrPassedOn.firstSentence(of: "Version 2.4.1 is the newest stable one, e.g. for the build box and for every laptop we hand out.").hasPrefix("Version 2.4.1 is the newest stable one, e.g."))
    }

    @Test func aLongLineIsCutAtAWordNeverInsideOne() {
        let line = "Which version of the registry server does the package index of the team list as stable today because I need the exact number for the lock file"
        let words = Set(line.split(separator: " ").map(String.init))
        for limit in [110, 90, 72, 56, 42, 30, 20] {
            let cut = HerdrPassedOn.firstSentence(of: line, limit: limit)
            #expect(cut.hasSuffix("…") && cut.count <= limit + 1)
            for word in cut.dropLast().split(separator: " ") { #expect(words.contains(String(word)), "“\(word)” is not a whole word of the line (limit \(limit))") }
        }
        #expect(HerdrPassedOn.firstSentence(of: "Short enough.", limit: 20) == "Short enough.")
    }

    @Test func aRequestForABotNamesTheBotInItsFoldedLine() {
        let text = HerdrBotRelay.request(from: "Boppy", HerdrBotAsk(name: "Legal", purpose: "People keep sending me contracts to review, which is not product work."))
        let shown = HerdrPassedOn(text)
        #expect(shown.botName == "Legal")
        #expect(shown.summary == "Legal: People keep sending me contracts to review, which is not product work.")
        #expect(!shown.summary.contains("passed on"), "the lines that are for the agent alone are never shown")
    }

    // MARK: Both sides of an exchange

    @Test func theSendersChatShowsItsMessageAsTheSameKindOfCard() throws {
        let store = makeStore()
        let infra = Bot(name: "Infra", backend: .herdr), jarvis = Bot(name: "Jarvis", backend: .herdr)
        store.bots = [jarvis, infra]
        let text = "Please set up the registry.\n\nSteps:\n1. Install it.\n2. Say “done”."
        // The line as the app writes it into the sender's chat (and as older versions stored it).
        let line = AppOnlyLine.line(HerdrMessageLine.sent.render(jarvis.name, infra.name, text))
        let row = try #require(store.herdrPassedOnRow(line))
        #expect(row.id == line.id && row.title == "Message to Infra" && row.sender === jarvis)
        #expect(row.shown.body == text, "the whole text is there to unfold, quotes inside it included")
        #expect(row.summary == "Please set up the registry.")
        // The other side: the message in the receiving bot's chat.
        let received = ChatMessage(role: .user, content: HerdrBotRelay.message(from: jarvis.name, text),
                                   metadata: [HerdrBotRelay.Key.kind: HerdrBotRelay.message, HerdrBotRelay.Key.asker: jarvis.id.uuidString.lowercased(), HerdrBotRelay.Key.name: jarvis.name])
        let other = try #require(store.herdrPassedOnRow(received))
        #expect(other.title == "Message from Jarvis" && other.sender === jarvis && other.summary == row.summary)
        // Any other line of the app, and what the person wrote, are not cards.
        #expect(store.herdrPassedOnRow(AppOnlyLine.line(HerdrMessageLine.answered.render("Infra", "Jarvis"))) == nil)
        #expect(store.herdrPassedOnRow(ChatMessage(role: .system, content: "Infra wrote to Jarvis: “hello”")) == nil, "only the app's own tagged line")
        #expect(store.herdrPassedOnRow(ChatMessage(role: .user, content: "Infra wrote to Jarvis: “hello”")) == nil)
    }

    @Test func aTemplateGivesBackTheValuesItWasRenderedWith() {
        let template = LineTemplate("", " wrote to ", ": “", "”")
        #expect(template.values(in: template.render("Infra", "Jarvis", "one “two” three")) == ["Infra", "Jarvis", "one “two” three"])
        #expect(template.values(in: "Infra wrote something else") == nil)
        #expect(LineTemplate("You removed ", ", which ", " had created.").values(in: "You removed Legal, which Jarvis had created.") == ["Legal", "Jarvis"])
    }

    // MARK: The colour of the bot whose words they are

    private func surfaces() -> [(dark: Bool, chat: RGB, text: RGB)] {
        [(false, Palette.rgb(Palette.chat, dark: false), Palette.rgb(Palette.graphite, dark: false)), (true, Palette.rgb(Palette.chat, dark: true), Palette.rgb(Palette.graphite, dark: true))]
    }

    @Test func everyAvatarColourGivesACardThatCanBeRead() {
        for colour in AvatarColour.allCases {
            for surface in surfaces() {
                let pair = BotTint.pair(colour.swatch(dark: surface.dark), dark: surface.dark)
                let card = BotTintPair.cardSurface(fill: pair.fill, on: surface.chat)
                // The card above the message box lies on the card surface, with the same wash.
                let raised = BotTintPair.cardSurface(fill: pair.fill, on: Palette.rgb(Palette.card, dark: surface.dark))
                #expect(pair.ink.contrast(with: raised) >= 4.5 && surface.text.contrast(with: raised) >= 4.5, "a card above the message box: \(colour.rawValue), \(surface.dark ? "dark" : "light")")
                let place = "\(colour.rawValue), \(surface.dark ? "dark" : "light")"
                #expect(pair.ink.contrast(with: card) >= 4.5, "the label on its card: \(place)")
                #expect(surface.text.contrast(with: card) >= 4.5, "the message's words on the card: \(place)")
                #expect(pair.ink.contrast(with: surface.chat) >= 4.5, "the bot's name above its replies: \(place)")
                // The card can be told from the chat around it: its outline, and its surface.
                #expect(pair.fill.over(surface.chat, opacity: BotTintPair.border).contrast(with: surface.chat) >= 1.5, "the outline: \(place)")
                #expect(card != surface.chat)
            }
        }
    }

    @Test func aWhiteBlackOrGreyAvatarStillGivesAnAccent() {
        for surface in surfaces() {
            for (name, avatar) in [("white", RGB.white), ("black", RGB.black), ("grey", RGB(0x777777)), ("almost white", RGB(0xF4F4F0)), ("almost black", RGB(0x121212))] {
                let pair = BotTintPair(avatar: avatar, dark: surface.dark, surface: surface.chat)
                let card = BotTintPair.cardSurface(fill: pair.fill, on: surface.chat), place = "\(name), \(surface.dark ? "dark" : "light")"
                #expect(pair.fill.contrast(with: surface.chat) >= 2.2, "never white on white or black on black: \(place)")
                #expect(pair.fill.chroma > 0.03, "a warm neutral, not a plain grey: \(place)")
                #expect(pair.ink.contrast(with: card) >= 4.5, "the label: \(place)")
            }
        }
        // A black avatar is drawn white on dark: its card there is cream, not the grey of an unlit surface.
        let jarvis = BotTintPair(avatar: AvatarColour.black.swatch(dark: true), dark: true, surface: Palette.rgb(Palette.chat, dark: true))
        #expect(jarvis.fill == BotTintPair.cream)
    }

    @Test func loudPaleAndDarkAccentsOfClassicAvatarsAreBroughtIntoRange() throws {
        for surface in surfaces() {
            for hex in ["#FFFF00", "#FFE9A8", "#0A1B3D", "#1084FE", "#FF263C", "#00FF7F"] {
                let avatar = try #require(RGB(hex: hex))
                let pair = BotTintPair(avatar: avatar, dark: surface.dark, surface: surface.chat)
                #expect(pair.ink.contrast(with: BotTintPair.cardSurface(fill: pair.fill, on: surface.chat)) >= 4.5, "\(hex), \(surface.dark ? "dark" : "light")")
                #expect(pair.fill.contrast(with: surface.chat) >= 2.2, "\(hex), \(surface.dark ? "dark" : "light")")
            }
        }
    }

    @Test func aBotCarriesOneColourWhereverItSpeaks() {
        let store = makeStore()
        let infra = Bot(name: "Infra", backend: .herdr); infra.avatarMark = AvatarMark(shape: "hex", colour: AvatarColour.cyan.rawValue)
        let classic = Bot(name: "Fox", backend: .herdr); classic.avatarMark = nil; classic.accentColor = "#FFFFFF"
        store.bots = [infra, classic]
        // Its name above its replies, and the card that carries its words into another chat, come from the same pair.
        #expect(infra.avatarRGB(accent: "Clay").dark == AvatarColour.cyan.swatch(dark: true))
        #expect(classic.avatarRGB(accent: "Clay").light == RGB.white)
        // A classic avatar without a colour of its own takes the app's accent; Graphite is a neutral.
        classic.accentColor = nil
        #expect(classic.avatarRGB(accent: "Sage").light == Palette.rgb(Palette.sage, dark: false))
        let graphite = BotTintPair(avatar: classic.avatarRGB(accent: "Graphite").dark, dark: true, surface: Palette.rgb(Palette.chat, dark: true))
        #expect(graphite.fill == BotTintPair.cream)
    }

    @Test func contrastIsMeasuredTheWayTheGuidelineDefinesIt() {
        #expect(abs(RGB.white.contrast(with: .black) - 21) < 0.001)
        #expect(abs(RGB(0x777777).contrast(with: .white) - 4.48) < 0.01)
        #expect(RGB(0x336699).over(.white, opacity: 0) == .white)
        #expect(RGB(0xB35F2B).hex == 0xB35F2B)
    }
}

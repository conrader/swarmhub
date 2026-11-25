import Foundation

/// The words of "About you" and of the main bot's introduction, wherever the app shows them.
enum AboutYouCopy {
    static let title = "About you"
    static let detail = "What your bots should know about you. Every bot reads it, so none has to ask again. Your main bot may suggest additions; nothing is added without your OK."
    static let prompt = "For example: what to call you, what you work on, how you like answers."
    static func count(_ used: Int) -> String { "\(used) of \(HerdrAboutYou.limit) characters" }

    static func cardTitle(_ bot: String) -> String { "\(bot) would like to remember this about you" }
    static let save = "Remember", dismiss = "Don’t save"
    static let full = "“About you” is full. Shorten it in Settings → General, then try again."
    static func saved(_ bot: String) -> String { "Saved to About you. Your bots will know from their next message." }

    static func offerTitle(_ bot: String) -> String { "Let \(bot) get to know you" }
    static let offerDetail = "A few short questions, so your bots know who they work for. You can skip any of them."
    static let offerStart = "Start", offerLater = "Not now"
}

/// "About you" (`HerdrAboutYou`) and the main bot's first conversation (`HerdrIntro`).
/// The text lives in the app's settings and is given to every bot's agent with its instructions. Only a server's main
/// bot proposes additions, in its replies; each waits above the composer until the person says Remember or Don't save.
/// The introduction is one message the app sends for the person: when the person accepts its offer;
/// the composer menu also lets them ask for it later.
extension AppStore {
    static let aboutYouKey = "aboutYou"
    /// `UserDefaults`: the additions already saved or dismissed, as `<message id>#<line number>`, newest last.
    static let aboutYouHandledKey = "aboutYouHandled", aboutYouHandledKept = 200
    /// `UserDefaults`, per main bot: the introduction was started (`started`) or its offer was put away (`dismissed`).
    static func herdrIntroKey(_ botID: UUID) -> String { "herdrIntro.\(botID.uuidString.lowercased())" }
    static let introStarted = "started", introDismissed = "dismissed"

    var aboutYou: String {
        get { defaults.string(forKey: Self.aboutYouKey) ?? "" }
        set { defaults.set(HerdrAboutYou.clean(newValue), forKey: Self.aboutYouKey); objectWillChange.send() }
    }

    // MARK: Additions waiting for the person

    struct PendingAboutYou: Identifiable, Equatable { let id: String; let text: String }

    /// The additions the main bot's newest finished reply proposes that were neither saved nor dismissed and are not
    /// in the text already. An older reply's proposals are no longer offered once the bot has answered again.
    func pendingAboutYou(for bot: Bot) -> [PendingAboutYou] {
        guard createsHerdrBots(bot), isIdle(bot),
              let reply = bot.messages.last(where: { $0.role == .assistant && $0.presentation == .text }), !reply.isStreaming else { return [] }
        let handled = Set(defaults.stringArray(forKey: Self.aboutYouHandledKey) ?? [])
        let known = aboutYou.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return HerdrAboutYou.additions(in: TurnReplyText.complete(reply, in: bot)).enumerated().compactMap { index, line in
            let id = "\(reply.id.uuidString.lowercased())#\(index)"
            return handled.contains(id) || known.contains(line.lowercased()) ? nil : PendingAboutYou(id: id, text: line)
        }
    }

    /// The person agreed: the line joins the text. False when the text is full; the addition then stays offered.
    @discardableResult func acceptAboutYou(_ pending: PendingAboutYou) -> Bool {
        guard let next = HerdrAboutYou.adding(pending.text, to: aboutYou) else { return false }
        aboutYou = next
        dismissAboutYou(pending)
        return true
    }

    /// Saved or declined: the addition is not offered again.
    func dismissAboutYou(_ pending: PendingAboutYou) {
        let handled = (defaults.stringArray(forKey: Self.aboutYouHandledKey) ?? []).filter { $0 != pending.id } + [pending.id]
        defaults.set(Array(handled.suffix(Self.aboutYouHandledKept)), forKey: Self.aboutYouHandledKey)
        objectWillChange.send()
    }

    // MARK: The introduction

    func herdrIntroState(_ bot: Bot) -> String? { defaults.string(forKey: Self.herdrIntroKey(bot.id)) }

    /// A main bot that never introduced itself and whose offer was not put away shows the offer above its composer,
    /// quietly: nothing is sent until the person presses Start.
    func offersHerdrIntro(_ bot: Bot) -> Bool { createsHerdrBots(bot) && !bot.isDemo && herdrIntroState(bot) == nil && isIdle(bot) }

    func dismissHerdrIntro(_ bot: Bot) { defaults.set(Self.introDismissed, forKey: Self.herdrIntroKey(bot.id)); objectWillChange.send() }

    /// Has the main bot open the conversation: the app sends it the note that asks for the greeting and the
    /// questions (`HerdrIntro.note`), as one message the chat shows as a single line. It starts the bot's agent like
    /// any message, so the reply row says "Starting…" while it does. `again`: the person asked for it from the menu.
    /// Refused while the bot is answering, and for a bot that is not a main bot. Returns whether the note went out.
    @discardableResult func startHerdrIntro(for bot: Bot, again: Bool = false) -> Bool {
        guard createsHerdrBots(bot), isIdle(bot) else { return false }
        // Recorded first, so a note that could not be sent is not sent again by itself at the next launch.
        defaults.set(Self.introStarted, forKey: Self.herdrIntroKey(bot.id)); objectWillChange.send()
        let note = HerdrIntro.note(name: bot.name, about: aboutYou, projects: SettingsLayout.path(.servers, HerdrProjectsCopy.title), again: again)
        return send(text: note, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true, metadata: [HerdrIntro.Key.kind: again ? HerdrIntro.again : HerdrIntro.first])
    }
}

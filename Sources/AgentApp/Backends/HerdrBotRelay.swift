import Foundation

/// Only a server's main bot creates bots (`HerdrBotRequest`). Any other Herdr bot that wants one asks the main bot:
/// its reply ends with a ```swarmhub fence holding `{"op":"request_bot","name":…,"purpose":…}`. The app passes the
/// request into the main bot's chat as a message that says who asks, and passes the main bot's answer (created,
/// declined, or waiting for the person) back into the asking bot's chat. Foundation only: the blocks, the notes and
/// the passed-on messages also build on Linux for the live checks.
struct HerdrBotAsk: Equatable, Sendable {
    var name: String
    /// What the bot is for and why it is needed, in the asking bot's words.
    var purpose: String

    static let op = "request_bot", purposeLimit = 1_500, perReply = 3
    /// Only the note below (and a block that follows it) contains it: a running agent reads the note once.
    static let marker = "\"op\":\"\(op)\""

    /// Every request for a bot in a reply, one per name.
    static func asks(in reply: String) -> [HerdrBotAsk] {
        var found: [HerdrBotAsk] = []
        for object in HerdrBotRequest.objects(in: reply) where object["op"] as? String == op {
            guard let name = HerdrBotRequest.name(object["name"]), !found.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            let purpose = ((object["purpose"] as? String) ?? (object["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(HerdrBotAsk(name: name, purpose: String(purpose.prefix(purposeLimit))))
        }
        return Array(found.prefix(perReply))
    }

    /// What a bot that is not the main bot is told, after its standing instructions and once to a running agent.
    /// `main` is the main bot's name, when the server has one.
    static func note(main: String?) -> String {
        """
        You cannot create bots yourself: only the main bot\(main.map { ", \($0)," } ?? "") can. When you need another bot for a job that is not \
        yours, or the person asks you for one, ask the main bot through SwarmHub, the app the person is chatting from: \
        end your reply with one fenced block like this:

        ```swarmhub
        {"op":"\(op)","name":"Research","purpose":"What the new bot is for and why it is needed."}
        ```

        SwarmHub hides the block, passes your request on, and later sends you a message that starts with \
        "\(HerdrBotRelay.answerLead)" or "\(HerdrBotRelay.appLead)" with the outcome: created, declined, or waiting for the \
        person. Say that you asked, not that the bot exists. Ask once for each bot, do not repeat a request while you \
        wait, and never put a request in your reply to such a message.
        """
    }
}

/// The main bot refuses a request: `{"op":"decline_bot","name":…,"reason":…}` in a ```swarmhub fence.
struct HerdrBotDecline: Equatable, Sendable {
    var name: String?
    var reason: String

    static let op = "decline_bot", reasonLimit = 600

    static func declines(in reply: String) -> [HerdrBotDecline] {
        HerdrBotRequest.objects(in: reply).filter { $0["op"] as? String == op }.map { object in
            HerdrBotDecline(name: HerdrBotRequest.name(object["name"]),
                            reason: String(((object["reason"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(reasonLimit)))
        }
    }
}

/// The messages the app passes between an asking bot and the main bot, what the main bot's reply means, and how
/// often a bot may ask.
enum HerdrBotRelay {
    /// How a passed-on message starts, so an agent can tell it from what the person wrote. The messages keep to single
    /// line breaks: the chat shows a message of the person's side as one paragraph.
    static let requestLead = "[Request from the bot", answerLead = "[Answer from the main bot", appLead = "[From SwarmHub]"
    static let passedOn = "passed on by SwarmHub]"

    /// Message metadata (`ChatMessage.metadata`): `kind` is "request" on a request in the main bot's chat and "outcome"
    /// on an answer in the asking bot's chat; `asker` is the asking bot's id and `name` the bot asked for.
    enum Key { static let kind = "herdrRelay", asker = "herdrRelayAsker", name = "herdrRelayName" }
    static let request = "request", outcome = "outcome"

    /// What became of a request, as the asking bot is told.
    enum Outcome: Equatable, Sendable {
        /// The main bot created the bot, or the person accepted it.
        case created(String)
        /// The main bot left the decision to the person.
        case waiting(String)
        case declined(String?, reason: String)
        /// A bot of that name is already on the server.
        case taken(String)
        /// The person dismissed the main bot's request.
        case dismissed(String)
        /// The main bot answered in words, with no block the app can act on.
        case answered(String)
    }

    /// The request as the main bot reads it: who asks, for what, and that the answer is a block. How to write the
    /// block is in the main bot's note, which an agent that has not read it gets in front of this message.
    static func request(from asker: String, _ ask: HerdrBotAsk) -> String {
        """
        \(requestLead) \(asker), \(passedOn)
        \(asker) asks for a new bot named "\(ask.name)". Purpose: \(ask.purpose.isEmpty ? "(none given)" : ask.purpose)
        The person did not write this. You decide: end your reply with a \(HerdrBotRequest.op) block for "\(ask.name)" \
        ("decision" \(HerdrBotRequest.decidedWord) to create it now, \(HerdrBotRequest.askWord) to let the person decide) or a \(HerdrBotDecline.op) block with your reason. \
        SwarmHub tells \(asker) the outcome.
        """
    }

    /// One outcome in a sentence or two.
    static func words(_ outcome: Outcome, main: String) -> String {
        switch outcome {
        case .created(let name): "The bot \"\(name)\" you asked for now exists. The person can chat with it."
        case .waiting(let name): "\(main) proposed the bot \"\(name)\" to the person, who has not decided yet. You will be told when they do."
        case .declined(let name, let reason): "\(main) declined your request\(name.map { " for a bot named \"\($0)\"" } ?? "")\(reason.isEmpty ? "." : ": \(reason)")"
        case .taken(let name): "A bot named \"\(name)\" already exists on this server, so none was created."
        case .dismissed(let name): "The person dismissed the proposal for a bot named \"\(name)\". No bot was created."
        case .answered(let text): "\(main) created no bot and answered: \(text)"
        }
    }

    /// The main bot's answer as the asking bot reads it.
    static func answer(from main: String, _ outcomes: [Outcome]) -> String {
        "\(answerLead) \(main), \(passedOn)\n" + outcomes.map { words($0, main: main) }.joined(separator: "\n") + "\n\(noReply)"
    }

    /// What the person later did with a request the main bot left to them, as the asking bot reads it.
    static func decision(_ outcome: Outcome, main: String) -> String { "\(appLead)\n\(words(outcome, main: main))\n\(noReply)" }

    /// A server with no main bot: the asking bot is told, so it can tell the person.
    static func noMain(_ ask: HerdrBotAsk) -> String {
        "\(appLead)\nThis server has no main bot, so your request for a bot named \"\(ask.name)\" was not passed on. Tell the person: they can make one bot the main bot in its settings.\n\(noReply)"
    }

    static let noReply = "This is information for you, not a new request: do not ask for this bot again."

    /// What the main bot's reply to a passed-on request asks the app to do, in order: bots to create (decided, or to
    /// put before the person), refusals, and, with neither, the reply's own words.
    static func verdicts(in reply: String, visible: String) -> (creations: [HerdrBotRequest], declines: [HerdrBotDecline], words: String?) {
        let creations = HerdrBotRequest.requests(in: reply), declines = HerdrBotDecline.declines(in: reply)
        let words = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return (creations, declines, creations.isEmpty && declines.isEmpty ? String(words.prefix(HerdrBotDecline.reasonLimit)) : nil)
    }

    // MARK: How often

    /// One bot may have this many requests passed on within the window; so may the main bot create this many bots
    /// on its own decision. Beyond it a request is not passed on, and a decided bot waits for the person instead.
    static let askLimit = 3, createLimit = 5, window: TimeInterval = 600

    /// `times`: when earlier ones went through (seconds since the reference date). True while another may.
    static func allowed(_ times: [Double], limit: Int, now: Double) -> Bool { recent(times, now: now).count < limit }
    static func recent(_ times: [Double], now: Double) -> [Double] { times.filter { now - $0 < window && $0 <= now } }

    /// A reply to a message the app passed on never starts another request: that is what keeps two agents from
    /// answering each other for ever.
    static func mayAsk(replyingTo metadata: [String: String]) -> Bool { metadata[Key.kind] == nil }
}

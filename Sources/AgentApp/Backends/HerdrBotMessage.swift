import Foundation

/// One Herdr bot writes to another bot on the same server: its reply ends with a ```swarmhub fence holding
/// `{"op":"message_bot","to":…,"message":…}`. The app puts the message into the other bot's chat, marked as coming
/// from the sender, and passes that bot's reply back into the sender's chat, so both chats show the whole exchange
/// (`AppStore+HerdrMessages.swift`). A bot may write to the same bot again when its answer has come (a follow-up),
/// as the Bots of Grok Bot hand work to each other and reply later; what ends an exchange is in `HerdrBotRelay`.
/// The fence, the passed-on messages and the limits are the family of `HerdrBotRelay`. Foundation only: the block,
/// the notes and the rules also build on Linux for the live checks.
struct HerdrBotMessage: Equatable, Sendable {
    /// The bot's name as the sender wrote it.
    var to: String
    var text: String

    static let op = "message_bot", textLimit = 4_000, answerLimit = 6_000, perReply = 3
    /// Only the note below (and a block that follows it) contains it: a running agent reads the note once.
    static let marker = "\"op\":\"\(op)\""

    /// Every message to another bot in a reply, one per name. A block with no text is no message.
    static func messages(in reply: String) -> [HerdrBotMessage] {
        var found: [HerdrBotMessage] = []
        for object in HerdrBotRequest.objects(in: reply) where object["op"] as? String == op {
            guard let to = HerdrBotRequest.name(object["to"] ?? object["name"] ?? object["bot"]), !found.contains(where: { $0.to.caseInsensitiveCompare(to) == .orderedSame }) else { continue }
            let text = ((object["message"] as? String) ?? (object["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { found.append(HerdrBotMessage(to: to, text: String(text.prefix(textLimit)))) }
        }
        return Array(found.prefix(perReply))
    }

    /// What every Herdr bot is told, after its standing instructions and once to a running agent. Who can be written
    /// to is not in it: that is `roster`, which changes.
    static let note = """
        You can write to the other bots on this server through SwarmHub, the app the person is chatting from. To send \
        one a message, end your reply with a fenced block like this:

        ```swarmhub
        {"op":"\(op)","to":"Name of the bot","message":"What you ask or tell it, with everything it needs to know."}
        ```

        SwarmHub hides the block, puts your message into that bot's chat and later sends you its answer as a message \
        that starts with "\(HerdrBotRelay.replyLead)". The other bot knows nothing of this conversation, and the person \
        can read both chats. Write to a bot when its job is needed, not to chat, and wait for its answer. After its \
        answer you may write to it again to follow up, at most \(HerdrBotRelay.roundLimit) times about one matter. \
        A message that starts with "\(HerdrBotRelay.messageLead)" comes from another bot: just answer it. \
        Your whole reply goes back to that bot by itself, so never address it with a block; if you must ask one other \
        bot first, write to that one only, and answer when its answer has come.
        """

    // MARK: Who can be written to

    /// How the line of names starts. An agent has read the current names when the newest of its tasks that contains
    /// this also contains the whole line (`HerdrClient.notes`' `changing`).
    static let rosterLead = "Bots you can write to on this server right now:"
    static let rosterNames = 40

    /// The names a bot can write to, as one line. It is told again, alone, when it changes.
    static func roster(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names.map(line) where !name.isEmpty && !unique.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { unique.append(name) }
        guard !unique.isEmpty else { return "\(rosterLead) none. SwarmHub tells you when that changes." }
        let more = unique.count > rosterNames ? ", and \(unique.count - rosterNames) more" : ""
        return "\(rosterLead) " + unique.prefix(rosterNames).map { "\"\($0)\"" }.joined(separator: ", ") + more + ". Use a name exactly as it is written here."
    }

    /// A name on one line, as the roster and the passed-on messages write it.
    static func line(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\"", with: "'").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Whom a message reaches

    /// A bot a message could go to: `open` is its "Other bots can message it".
    struct Candidate: Equatable, Sendable { var id: String; var name: String; var open = true }

    /// Why a message is not delivered.
    enum Refusal: Equatable, Sendable {
        /// No bot of that name on the server (or the sender's own name).
        case unknown
        /// More than one bot there has the name.
        case ambiguous
        /// The bot's "Other bots can message it" is off.
        case closed
        /// The exchange has passed through `HerdrBotRelay.chainLimit` bots, and this would be one more.
        case tooLong
        /// The sender and this bot have written to each other `HerdrBotRelay.roundLimit` times in this exchange.
        case spent
    }

    enum Target: Equatable, Sendable { case bot(String), refused(Refusal) }

    /// The bots a name means: the same name on one line, whatever its case and accents.
    static func bots(named name: String, among others: [Candidate]) -> [Candidate] {
        let wanted = line(name)
        return others.filter { line($0.name).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The bot `name` means among `others` (every bot of the server but the sender), and whether a message of an
    /// exchange that has passed through `chain` (bot ids, the sender included) may reach it from `sender`. `rounds`:
    /// how often each two bots have written to each other in the exchange (`HerdrBotRelay.pair`). A bot that is
    /// already part of the exchange can be written to again (a follow-up), until the two have written to each other
    /// `roundLimit` times; a bot that is new to it only while the exchange has room for one more.
    static func target(named name: String, among others: [Candidate], chain: [String], from sender: String = "", rounds: [String: Int] = [:]) -> Target {
        let matches = bots(named: name, among: others)
        guard let match = matches.first else { return .refused(.unknown) }
        guard matches.count == 1 else { return .refused(.ambiguous) }
        if rounds[HerdrBotRelay.pair(sender, match.id), default: 0] >= HerdrBotRelay.roundLimit { return .refused(.spent) }
        if !chain.contains(match.id), chain.count >= HerdrBotRelay.chainLimit { return .refused(.tooLong) }
        return match.open ? .bot(match.id) : .refused(.closed)
    }
}

/// The messages the app passes between two bots that write to each other, and the limits of such an exchange.
extension HerdrBotRelay {
    /// How a bot's message and its answer start in the other bot's chat.
    static let messageLead = "[Message from the bot", replyLead = "[Answer from the bot"

    /// `Key.kind` on what the app puts into a chat for an exchange: `message` in the receiving bot's chat, `answer`
    /// (the receiver's reply) in the sender's, `notice` (a message that was not delivered) in the sender's.
    static let message = "message", answer = "answer", notice = "notice"
    static let exchangeKinds: Set<String> = [message, answer, notice]

    /// More metadata of those messages. `chain`: the ids of the bots the exchange has passed through, each once, in
    /// the order they joined, joined by commas. `waiting`: the ids of the bots further back that are still owed an
    /// answer (A, when A wrote to B and B then wrote to C), in order. `from`: the bot whose words an answer carries.
    /// `rounds`: how often each two bots wrote to each other in this exchange so far, this message included
    /// (`joined(rounds:)`). On these messages `asker` is the bot that wrote the message, and `name` the other bot's
    /// name when it was passed on.
    enum ExchangeKey { static let chain = "herdrRelayChain", waiting = "herdrRelayWaiting", from = "herdrRelayFrom", rounds = "herdrRelayRounds" }

    /// An exchange starts with what a bot writes after a message of the person, and lasts while bots answer what the
    /// app passed on to them: one piece of work. Within it bots write to each other as the work needs, also to a bot
    /// that already answered (a follow-up), as Grok Bot's Bots do. Three limits keep it from running by itself for
    /// ever (`docs/bot-communication.md`): it passes through at most `chainLimit` different bots, the same two bots
    /// write to each other at most `roundLimit` times in it (each message with the answer that comes back), and one
    /// bot has at most `messageLimit` messages passed on within `window`. Two bots that keep answering each other
    /// therefore stop after `roundLimit` messages, and only a message of the person starts a new exchange.
    static let chainLimit = 4, messageLimit = 6, roundLimit = 8

    /// Two bots, whoever of them writes: the key their messages are counted under.
    static func pair(_ one: String, _ other: String) -> String { [one.lowercased(), other.lowercased()].sorted().joined(separator: "+") }

    /// How often each two bots have written to each other in the exchange a message with this `rounds` value belongs
    /// to; a message passed on before the count was kept starts it.
    static func rounds(_ value: String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in (value ?? "").split(separator: ",") {
            let parts = entry.split(separator: ":")
            if parts.count == 2, let count = Int(parts[1]), count > 0 { counts[String(parts[0]).lowercased()] = count }
        }
        return counts
    }

    static func joined(rounds: [String: Int]) -> String { rounds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",") }

    static func ids(_ value: String?) -> [String] { (value ?? "").split(separator: ",").map { String($0).lowercased() } }
    static func joined(_ ids: [String]) -> String { ids.map { $0.lowercased() }.joined(separator: ",") }

    /// The message as the receiving bot reads it.
    static func message(from sender: String, _ text: String) -> String {
        let sender = HerdrBotMessage.line(sender)
        return """
            \(messageLead) \(sender), \(passedOn)
            \(text)
            (The person did not write this. Your reply goes back to \(sender) by itself, and the person can read both chats.)
            """
    }

    /// The receiver's reply as the sender reads it. `visible` is the reply without its ```swarmhub fences.
    static func reply(from receiver: String, _ visible: String) -> String {
        let receiver = HerdrBotMessage.line(receiver), words = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            \(replyLead) \(receiver), \(passedOn)
            \(words.isEmpty ? "(\(receiver) answered without words.)" : String(words.prefix(HerdrBotMessage.answerLimit)))
            (This is \(receiver)'s answer to the message you sent it. The person did not write it.)
            """
    }

    /// Why a message was not delivered, as its sender reads it, with the names it can write to.
    static func refusal(_ refusal: HerdrBotMessage.Refusal, to name: String, names: [String]) -> String {
        let name = HerdrBotMessage.line(name)
        let why: String
        switch refusal {
        case .unknown: why = "No bot named \"\(name)\" can be written to on this server, so your message was not sent."
        case .ambiguous: why = "More than one bot on this server is named \"\(name)\", so your message was not sent. Tell the person: they have to rename one."
        case .closed: why = "\"\(name)\" does not take messages from other bots, so your message was not sent. Tell the person if you need it: they can allow it in that bot's settings."
        case .tooLong: why = "This exchange has already passed through \(chainLimit) bots, which is the limit, so your message to \"\(name)\" was not sent. Work with what you have, and tell the person what is still open."
        case .spent: why = "You and \"\(name)\" have written to each other \(roundLimit) times about this, which is the limit, so your message was not sent. Bring the matter to the person: tell them what is still open."
        }
        return "\(appLead)\n\(why)\n\(HerdrBotMessage.roster(names))"
    }

    /// A reply without its closed ```swarmhub fences: what one bot's answer is for another (the fence rules of
    /// `HerdrBotRequest.fences`).
    static func visible(_ reply: String) -> String {
        let lines = reply.components(separatedBy: "\n"); var kept: [String] = []; var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix { $0 == "`" }.count
            guard ticks >= 3, trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased() == "swarmhub" else { kept.append(lines[index]); index += 1; continue }
            var end = index + 1
            while end < lines.count {
                let line = lines[end].trimmingCharacters(in: .whitespaces)
                if line.count >= ticks, line.allSatisfy({ $0 == "`" }) { break }
                end += 1
            }
            // An unclosed fence is a reply that was cut: nothing after its opening line is anyone's words.
            index = end + 1
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

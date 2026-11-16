import Foundation

/// One Herdr bot writes to another bot on the same server: its reply ends with a ```swarmhub fence holding
/// `{"op":"message_bot","to":…,"message":…}`. The app puts the message into the other bot's chat, marked as coming
/// from the sender, and passes that bot's reply back into the sender's chat, so both chats show the whole exchange
/// (`AppStore+HerdrMessages.swift`). The fence, the passed-on messages and the limits are the family of
/// `HerdrBotRelay`. Foundation only: the block, the notes and the rules also build on Linux for the live checks.
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
        can read both chats. Write to a bot when its job is needed, not to chat, and wait for its answer instead of \
        writing again. A message that starts with "\(HerdrBotRelay.messageLead)" comes from another bot: just answer it. \
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
        /// The bot is already part of the exchange this message belongs to.
        case inChain
        /// The exchange has passed through `HerdrBotRelay.chainLimit` bots.
        case tooLong
    }

    enum Target: Equatable, Sendable { case bot(String), refused(Refusal) }

    /// The bots a name means: the same name on one line, whatever its case and accents.
    static func bots(named name: String, among others: [Candidate]) -> [Candidate] {
        let wanted = line(name)
        return others.filter { line($0.name).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The bot `name` means among `others` (every bot of the server but the sender), and whether a message of an
    /// exchange that has passed through `chain` (bot ids, the sender included) may reach it.
    static func target(named name: String, among others: [Candidate], chain: [String]) -> Target {
        let matches = bots(named: name, among: others)
        guard let match = matches.first else { return .refused(.unknown) }
        guard matches.count == 1 else { return .refused(.ambiguous) }
        if chain.contains(match.id) { return .refused(.inChain) }
        if chain.count >= HerdrBotRelay.chainLimit { return .refused(.tooLong) }
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

    /// More metadata of those messages. `chain`: the ids of the bots the exchange has passed through, in order,
    /// joined by commas. `waiting`: the ids of the bots further back that are still owed an answer (A, when A wrote to
    /// B and B then wrote to C), in order. `from`: the bot whose words an answer carries. On these messages `asker`
    /// is the bot that wrote the message, and `name` the other bot's name when it was passed on.
    enum ExchangeKey { static let chain = "herdrRelayChain", waiting = "herdrRelayWaiting", from = "herdrRelayFrom" }

    /// An exchange passes through at most this many bots (A writes to B, B to C, C to D), and one bot may have this
    /// many messages passed on within `window`. A bot that is already part of an exchange is never written to again
    /// within it, so two bots cannot answer each other for ever: an exchange only grows by a new bot, up to the limit.
    static let chainLimit = 4, messageLimit = 6

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
        case .inChain: why = "\"\(name)\" is already part of this exchange, and a bot is written to only once in an exchange, so your message was not sent. Work with what you have, and tell the person what is still open. A reply to a bot that wrote to you goes back to it by itself."
        case .tooLong: why = "This exchange has already passed through \(chainLimit) bots, which is the limit, so your message to \"\(name)\" was not sent. Work with what you have, and tell the person what is still open."
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

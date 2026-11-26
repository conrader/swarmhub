import Foundation

/// What the app writes into a chat about messages between bots. App-only lines: the person reads them, no agent does.
enum HerdrMessageLine {
    /// In the sender's chat: what it wrote, since its own reply hides the block.
    static let sent = LineTemplate("", " wrote to ", ": “", "”")
    /// What the folded card of such a line is called, as "Message from …" names the other side.
    static func sentTitle(to name: String) -> String { "Message to \(name)" }
    static let notSent = LineTemplate("", "’s message to ", " could not be delivered.")
    static let tooMany = LineTemplate("", "’s message to “", "” was not sent: it has written to other bots ", " times in the last ", " minutes.")
    /// A bot that was told a message was not sent wrote one again that cannot be sent: it is not told a second time.
    static let refusedAgain = LineTemplate("", "’s message to “", "” was not sent either. ", " was not told again, so it stops here.")
    /// In the chat of the bot that was to be written to, when the two have reached their limit.
    static let limitReached = LineTemplate("", " and ", " have written to each other ", " times about this, which is the limit. ", " was told to bring the matter to you.")
    static let oneWhileAnswering = LineTemplate("", " is answering another bot and may write to one bot before it answers. Only its message to “", "” was looked at.")
    /// In the answering bot's chat.
    static let answered = LineTemplate("", "’s answer was passed back to ", ".")
    static let answerNotPassed = LineTemplate("", "’s answer could not be passed back to ", ".")
    /// In the chat of the bot that waits for an answer.
    static let askedOn = LineTemplate("", " wrote to ", " before answering ", ".")
    static let unfinished = LineTemplate("", " did not finish its answer to ", "’s message, so the exchange ended there.")
    static let stopped = LineTemplate("", " was stopped before it read what ", " sent, so the exchange ended there.")

    /// How much of a message the sender's chat quotes; the whole of it is in the other bot's chat.
    static let quoted = 1_200
    static func quote(_ text: String) -> String { text.count > quoted ? String(text.prefix(quoted)) + "…" : text }
}

/// Bots that write to each other, on Herdr. Any bot can write to another bot of its server by name
/// (`HerdrBotMessage`): the app puts the message into that bot's chat as its next message, marked as passed on, and
/// passes the reply back into the sender's chat, so both chats show everything the bots said. A bot that is asked
/// while it answers another bot's message may write to one further bot first; its own answer then goes back when that
/// bot has answered. A bot that has its answer may write to the same bot again (a follow-up), as Grok Bot's Bots
/// hand work to each other and reply later. What keeps an exchange from running by itself is in `HerdrBotRelay`. The same two bots write to each other eight times at most, and one bot has six
/// messages passed on in ten minutes. The person ends an exchange by stopping the bot that is answering.
extension AppStore {
    // MARK: Who can be written to

    /// "Other bots can message it", on unless the person turned it off.
    static func herdrTakesMessagesKey(_ botID: UUID) -> String { "herdrTakesMessages.\(botID.uuidString.lowercased())" }
    func herdrTakesMessages(_ bot: Bot) -> Bool { defaults.object(forKey: Self.herdrTakesMessagesKey(bot.id)) as? Bool ?? true }
    func setHerdrTakesMessages(_ on: Bool, for bot: Bot) { defaults.set(on, forKey: Self.herdrTakesMessagesKey(bot.id)); objectWillChange.send() }

    /// `UserDefaults`: when this bot's messages were passed on or refused (`HerdrBotRelay.messageLimit`).
    static func herdrMessageTimesKey(_ botID: UUID) -> String { "herdrBotMessages.\(botID.uuidString.lowercased())" }

    /// The other bots on `bot`'s server.
    func herdrPeers(of bot: Bot) -> [Bot] { herdrBots(on: herdrServer(for: bot)).filter { $0.id != bot.id && !$0.isReadOnlyArchive } }

    /// The names `bot` can write to, as its agent is told them (`HerdrBackend.roster`): the other bots of its server
    /// that take messages. The agent is told again when a bot is added, renamed, removed or switched.
    func herdrRoster(for bot: Bot) -> String { HerdrBotMessage.roster(herdrPeers(of: bot).filter(herdrTakesMessages).map(\.name)) }

    // MARK: When a reply ends

    private static func herdrID(_ bot: Bot) -> String { bot.id.uuidString.lowercased() }
    private func herdrBot(id: String) -> Bot? { bots.first { Self.herdrID($0) == id && $0.backend == .herdr } }

    /// The message of an exchange among the user messages a reply answers, unless that exchange was ended there.
    private func herdrExchangePart(in triggers: [ChatMessage]) -> ChatMessage? {
        triggers.first { HerdrBotRelay.exchangeKinds.contains($0.metadata[HerdrBotRelay.Key.kind] ?? "") && $0.metadata[Self.herdrExchangeEndedKey] == nil }
    }

    /// The ids of the bots that are owed an answer once `part` is answered, nearest last: those further back in the
    /// exchange, and the bot that wrote `part` when it is a message.
    private func herdrOwed(by part: ChatMessage?) -> [String] {
        guard let part else { return [] }
        var owed = HerdrBotRelay.ids(part.metadata[HerdrBotRelay.ExchangeKey.waiting])
        if part.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.message, let sender = part.metadata[HerdrBotRelay.Key.asker] { owed.append(sender) }
        return owed
    }

    /// Set on a passed-on message whose exchange the person ended before the bot read it: no later reply answers it.
    static let herdrExchangeEndedKey = "herdrRelayEnded"

    /// Called when a Herdr bot's turn in its own chat ends, with the user messages the reply answers. The messages
    /// the reply addresses to other bots are delivered, or refused back to it; and when the reply answers another
    /// bot's message, it is passed back to that bot, unless this bot wrote to a further bot first. A reply that did
    /// not finish (the person stopped it, or it failed) sends nothing and ends the exchange it was part of.
    func herdrMessagesEnded(_ text: String, from bot: Bot, triggers: [ChatMessage], finished: Bool, passOutgoing: Bool = true) {
        let part = herdrExchangePart(in: triggers), owed = herdrOwed(by: part)
        guard finished else { herdrExchangeBroke(at: bot, owed: owed, line: HerdrMessageLine.unfinished); return }
        let own = Self.herdrID(bot)
        let before = HerdrBotRelay.ids(part?.metadata[HerdrBotRelay.ExchangeKey.chain]), chain = before.isEmpty ? [own] : before
        // How often each two bots have written to each other in this exchange: what bounds two that keep following up.
        let rounds = HerdrBotRelay.rounds(part?.metadata[HerdrBotRelay.ExchangeKey.rounds])
        let peers = herdrPeers(of: bot), open = peers.filter(herdrTakesMessages).map(\.name)
        let candidates = peers.map { HerdrBotMessage.Candidate(id: Self.herdrID($0), name: $0.name, open: herdrTakesMessages($0)) }
        var messages = bot.documentReadOnly || !passOutgoing ? [] : HerdrBotMessage.messages(in: text)
        // A bot that answers another bot's message and still addresses that bot with a block has put its answer
        // there: those words go back with the reply, not as a new message.
        var answer = [HerdrBotRelay.visible(text)]
        if let asker = owed.last {
            messages.removeAll { message in
                guard HerdrBotMessage.bots(named: message.to, among: candidates).map(\.id) == [asker] else { return false }
                answer.append(message.text); return true
            }
        }
        if !owed.isEmpty, messages.count > 1 {
            notice(HerdrMessageLine.oneWhileAnswering.render(bot.name, messages[0].to), in: bot); messages = [messages[0]]
        }
        let times = Self.herdrMessageTimesKey(bot.id)
        // `carried`: something else now stands for the answer this bot owes (its message to a further bot, or the
        // refusal of one), so this reply is not the answer yet.
        var carried = false, askedOn: Bot?
        for message in messages {
            guard herdrAllowed(times, limit: HerdrBotRelay.messageLimit) else {
                notice(HerdrMessageLine.tooMany.render(bot.name, message.to, "\(HerdrBotRelay.messageLimit)", "\(Int(HerdrBotRelay.window / 60))"), in: bot)
                continue
            }
            herdrCount(times)
            var metadata = [HerdrBotRelay.ExchangeKey.chain: HerdrBotRelay.joined(chain), HerdrBotRelay.ExchangeKey.waiting: HerdrBotRelay.joined(owed),
                            HerdrBotRelay.ExchangeKey.rounds: HerdrBotRelay.joined(rounds: rounds)]
            switch HerdrBotMessage.target(named: message.to, among: candidates, from: own, rounds: rounds) {
            case .bot(let id):
                guard let target = peers.first(where: { Self.herdrID($0) == id }) else { continue }
                // A bot that already took part is written to again (a follow-up); a new one joins the exchange.
                metadata[HerdrBotRelay.ExchangeKey.chain] = HerdrBotRelay.joined(chain.contains(id) ? chain : chain + [id])
                metadata[HerdrBotRelay.ExchangeKey.rounds] = HerdrBotRelay.joined(rounds: rounds.merging([HerdrBotRelay.pair(own, id): 1], uniquingKeysWith: +))
                if herdrPassOn(HerdrBotRelay.message(from: bot.name, message.text), to: target, kind: HerdrBotRelay.message, asker: bot, name: bot.name, extra: metadata) {
                    notice(HerdrMessageLine.sent.render(bot.name, target.name, HerdrMessageLine.quote(message.text)), in: bot)
                    carried = true; askedOn = target
                } else { notice(HerdrMessageLine.notSent.render(bot.name, target.name), in: bot) }
            case .refused(let refusal):
                // A bot is told once why a message was not sent. One that answers that with another message that
                // cannot be sent is not told again, or it could go on trying for ever with nobody but the app.
                if part?.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.notice {
                    notice(HerdrMessageLine.refusedAgain.render(bot.name, message.to, bot.name), in: bot)
                    continue
                }
                // At the limit of two bots the other one's chat says so too; its agent is not woken for it.
                if refusal == .spent, let other = HerdrBotMessage.bots(named: message.to, among: candidates).first.flatMap({ match in peers.first { Self.herdrID($0) == match.id } }) {
                    notice(HerdrMessageLine.limitReached.render(bot.name, other.name, "\(HerdrBotRelay.roundLimit)", bot.name), in: other)
                }
                if herdrPassOn(HerdrBotRelay.refusal(refusal, to: message.to, names: open), to: bot, kind: HerdrBotRelay.notice, asker: bot, name: message.to, extra: metadata) { carried = true }
            }
        }
        guard let last = owed.last, let asker = herdrBot(id: last) else { return }
        if carried {
            if let askedOn { notice(HerdrMessageLine.askedOn.render(bot.name, askedOn.name, asker.name), in: asker) }
            return
        }
        let metadata = [HerdrBotRelay.ExchangeKey.chain: HerdrBotRelay.joined(chain), HerdrBotRelay.ExchangeKey.waiting: HerdrBotRelay.joined(Array(owed.dropLast())),
                        HerdrBotRelay.ExchangeKey.from: own, HerdrBotRelay.ExchangeKey.rounds: HerdrBotRelay.joined(rounds: rounds)]
        if herdrPassOn(HerdrBotRelay.reply(from: bot.name, answer.filter { !$0.isEmpty }.joined(separator: "\n\n")), to: asker, kind: HerdrBotRelay.answer, asker: asker, name: bot.name, extra: metadata) {
            notice(HerdrMessageLine.answered.render(bot.name, asker.name), in: bot)
        } else { notice(HerdrMessageLine.answerNotPassed.render(bot.name, asker.name), in: bot) }
    }

    /// An exchange ended at `bot` without its answer: every bot that waits for one reads why. They are not sent a
    /// message for it, so nothing starts again by itself; their person reads the line and may ask again.
    private func herdrExchangeBroke(at bot: Bot, owed: [String], line: LineTemplate) {
        guard let nearest = owed.last.flatMap(herdrBot(id:)) else { return }
        for waiting in owed.compactMap(herdrBot(id:)) where waiting.id != bot.id { notice(line.render(bot.name, nearest.name), in: waiting) }
    }

    // MARK: Stop

    /// The person's Stop in a bot's chat ends the exchanges there. The reply that is being written ends unfinished
    /// (`herdrMessagesEnded`); what another bot sent that still waits as the chat's next message is not sent at all,
    /// and the bots that wait for its answer read why.
    func herdrStopWaitingExchanges(in conversation: any Conversation) {
        guard let bot = conversation as? Bot, bot.backend == .herdr else { return }
        let waiting = turns.nextMessages.filter { next in
            next.conversation === bot && next.kind == .turn && !next.restored && HerdrBotRelay.exchangeKinds.contains(next.bubble.metadata[HerdrBotRelay.Key.kind] ?? "")
        }
        guard !waiting.isEmpty else { return }
        turns.nextMessages.removeAll { next in waiting.contains { $0.id == next.id } }
        for next in waiting {
            giveBack(next)
            herdrExchangeBroke(at: bot, owed: herdrOwed(by: next.bubble), line: HerdrMessageLine.stopped)
            next.bubble.metadata[Self.herdrExchangeEndedKey] = "1"
        }
        objectWillChange.send(); save()
    }

    // MARK: In the chat

    /// The caption over a message of an exchange, so it does not read as the person's own: who wrote it, whose answer
    /// it is, or that the app itself says a message was not sent.
    func herdrExchangeCaption(_ message: ChatMessage) -> String? {
        guard message.role == .user, let kind = message.metadata[HerdrBotRelay.Key.kind], HerdrBotRelay.exchangeKinds.contains(kind) else { return nil }
        let kept = message.metadata[HerdrBotRelay.Key.name]
        func name(_ key: String) -> String? { message.metadata[key].flatMap { id in bots.first { Self.herdrID($0) == id }?.name } ?? kept }
        switch kind {
        case HerdrBotRelay.message: return "Message from " + (name(HerdrBotRelay.Key.asker) ?? "another bot")
        case HerdrBotRelay.answer: return "Answer from " + (name(HerdrBotRelay.ExchangeKey.from) ?? "the other bot")
        default: return "Not sent" + (kept.map { " to \($0)" } ?? "")
        }
    }
}

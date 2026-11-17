import Foundation

/// Bots that create bots. Each server has one main bot: the Herdr bot there whose `canManageBots` flag is on
/// (`setCanManageBots` keeps it to one bot per server). On Herdr a bot
/// is only this app's record, so the main bot does nothing on the server: it asks in its reply (`HerdrBotRequest`).
/// A request it marked "decided" is created at once; any other waits above the composer for Create or Dismiss, and so
/// does every request while the main bot's "Ask me before creating bots" is on. Every other bot asks the main bot
/// (`HerdrBotRelay`): the app passes the request into the main bot's chat and its answer back.
extension AppStore {
    /// How the main bot asks, with the avatar words the app can draw; `…Asking` for a main bot whose person confirms
    /// every bot. Sent to the agent by `HerdrBackend`.
    static let herdrCreationNote = HerdrBotRequest.note(shapes: AvatarShape.grok, colours: AvatarColour.allCases.map(\.rawValue))
    static let herdrCreationNoteAsking = HerdrBotRequest.note(shapes: AvatarShape.grok, colours: AvatarColour.allCases.map(\.rawValue), asksFirst: true)
    /// `UserDefaults`: the requests already created or dismissed, as `<message id>#<name>`, newest last.
    static let herdrHandledRequestsKey = "herdrBotRequestsHandled", herdrHandledRequestsKept = 200
    /// `UserDefaults`: bots a main bot created on its own decision that the person has neither kept nor removed, as
    /// `<main bot id>#<new bot id>`, newest last.
    static let herdrUnaskedBotsKey = "herdrBotsCreatedUnasked", herdrUnaskedBotsKept = 20

    // MARK: The main bot

    /// Makes `bot` its server's main bot (and takes the role from any other bot there), or takes the role from it.
    func setCanManageBots(_ bot: Bot, _ on: Bool) {
        guard on else { bot.canManageBots = false; objectWillChange.send(); save(); return }
        guard bot.backend == .herdr else { return }
        let target = connection(of: bot)
        for other in bots where other.id != bot.id && other.canManageBots && connection(of: other) == target { other.canManageBots = false }
        bot.canManageBots = true; objectWillChange.send(); save()
    }

    /// A small line in a bot's chat: app-only, never sent to the agent (`AppOnlyLine`).
    func notice(_ text: String, in bot: Bot) {
        bot.messages.append(AppOnlyLine.line(text)); objectWillChange.send(); save()
    }

    /// `bot` is its server's main bot.
    func createsHerdrBots(_ bot: Bot) -> Bool { bot.backend == .herdr && bot.canManageBots && !bot.isReadOnlyArchive }

    func herdrMainBot(on server: HerdrServer) -> Bot? { herdrBots(on: server).first { createsHerdrBots($0) } }

    /// "Main bot of This Mac" for a server's main bot, which wears a star (`HerdrMainBotStar`); nil for every other bot.
    func herdrMainBotLabel(_ bot: Bot) -> String? { createsHerdrBots(bot) ? "Main bot of \(herdrServer(for: bot).name)" : nil }

    /// Stores whether this main bot needs the user's confirmation before it creates a bot.
    static func herdrAsksFirstKey(_ botID: UUID) -> String { "herdrAsksFirst.\(botID.uuidString.lowercased())" }
    func herdrAsksFirst(_ bot: Bot) -> Bool { defaults.bool(forKey: Self.herdrAsksFirstKey(bot.id)) }
    func setHerdrAsksFirst(_ on: Bool, for bot: Bot) { defaults.set(on, forKey: Self.herdrAsksFirstKey(bot.id)); objectWillChange.send() }

    // MARK: Requests waiting for the person

    /// One request waiting for the person's answer. `taken`: a Herdr bot with that name is already on the server.
    /// `askerID`: the bot whose passed-on request the main bot was answering.
    struct PendingHerdrBot: Identifiable, Equatable {
        let id: String; let request: HerdrBotRequest; let taken: Bool
        var askerID: UUID? = nil
    }

    /// The requests in the main bot's newest finished reply that were neither created nor dismissed. An older reply's
    /// requests are no longer offered once the bot has answered again, except those it made for another bot, which
    /// stay until the person answers, because that bot is waiting. Nothing the app is creating right now is offered.
    func pendingHerdrBots(for bot: Bot) -> [PendingHerdrBot] {
        guard createsHerdrBots(bot) else { return [] }
        let replies = bot.messages.suffix(60).filter { $0.role == .assistant && $0.presentation == .text && !$0.isStreaming }
        guard let newest = replies.last else { return [] }
        return replies.flatMap { reply -> [PendingHerdrBot] in
            let asker = herdrPassedOnRequest(answeredBy: reply, in: bot)?.metadata[HerdrBotRelay.Key.asker].flatMap(UUID.init(uuidString:))
            guard reply === newest ? isIdle(bot) || asker != nil : asker != nil else { return [] }
            return herdrRequests(in: reply, of: bot, askerID: asker).filter { !herdrSettling.contains($0.id) }
        }
    }

    /// The unhandled requests of one reply.
    func herdrRequests(in reply: ChatMessage, of bot: Bot, askerID: UUID? = nil) -> [PendingHerdrBot] {
        let handled = Set(defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? [])
        let names = Set(herdrBots(on: herdrServer(for: bot)).map { $0.name.lowercased() })
        return HerdrBotRequest.requests(in: reply.content).compactMap { request in
            let id = Self.herdrRequestID(reply.id, request)
            return handled.contains(id) ? nil : PendingHerdrBot(id: id, request: request, taken: names.contains(request.name.lowercased()), askerID: askerID)
        }
    }

    static func herdrRequestID(_ messageID: UUID, _ request: HerdrBotRequest) -> String { "\(messageID.uuidString.lowercased())#\(request.name.lowercased())" }

    /// The request is settled (created, dismissed, or its name is taken): it is not offered again.
    func dismissHerdrBot(_ pending: PendingHerdrBot) {
        let handled = (defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? []).filter { $0 != pending.id } + [pending.id]
        defaults.set(Array(handled.suffix(Self.herdrHandledRequestsKept)), forKey: Self.herdrHandledRequestsKey)
        objectWillChange.send()
    }

    /// The person pressed Dismiss. A bot that asked for this one is told.
    func refuseHerdrBot(_ pending: PendingHerdrBot, manager: Bot) {
        dismissHerdrBot(pending)
        tellHerdrAsker(of: pending, HerdrBotRelay.decision(pending.taken ? .taken(pending.request.name) : .dismissed(pending.request.name), main: manager.name))
    }

    /// A new Herdr bot on the main bot's server, with the requested name, avatar and instructions. `templates` are the
    /// server's (the caller read them; empty when it could not): a requested runtime that matches one is used,
    /// otherwise the new bot runs like the main bot. Called when the person presses Create, or for a request the main
    /// bot decided itself (`settleHerdrReply`).
    @discardableResult func createHerdrBot(_ pending: PendingHerdrBot, manager: Bot, templates: [HerdrClient.Template] = [],
                                           offered: [HerdrClient.Template.Model] = []) -> Bot? {
        guard createsHerdrBots(manager), !pending.taken else { dismissHerdrBot(pending); return nil }
        let request = pending.request, server = herdrServer(for: manager)
        guard !herdrBots(on: server).contains(where: { $0.name.caseInsensitiveCompare(request.name) == .orderedSame }) else {
            dismissHerdrBot(pending)
            return nil
        }
        let template = HerdrBotRequest.template(for: request.runtime, in: templates)
        let inherited = HerdrAgentReading.template(own: herdrTemplate(for: manager), shared: nil, in: templates).template
        let effective = template ?? inherited
        if let runtime = request.runtime, template == nil {
            errorMessage = "Couldn’t find the requested agent \(runtime) on \(server.name). Check its setup or ask for another agent."
            return nil
        }
        var model = HerdrModelChoice.recommended
        if let requested = request.model {
            if let listed = offered.first(where: { $0.id == requested }) {
                model = listed.id
            } else if effective?.modelAgent == "OpenCode", let id = HerdrModelChoice.apiModelID(requested) {
                model = id
            } else {
                errorMessage = "Couldn’t confirm model \(requested) on \(server.name). Choose a listed model or ask for Recommended."
                return nil
            }
        }
        let bot = Bot(name: request.name, title: "Created by \(manager.name)", persona: request.instructions.isEmpty ? Bot.defaultPersona : request.instructions, backend: .herdr)
        if request.shape != nil || request.colour != nil {
            bot.avatarMark = AvatarLook.effectiveMark(shape: request.shape, colour: request.colour, seed: bot.avatarSeed); bot.avatarMarkMigrated = false
        }
        bots.append(bot)
        setHerdrServer(server.id, for: bot)
        setHerdrTemplate(template?.name ?? herdrTemplate(for: manager) ?? "", for: bot)
        setHerdrModel(model, for: bot)
        dismissHerdrBot(pending)
        notice(AppOnlyLine.created.render(manager.name, bot.name), in: manager)
        return bot
    }

    /// Reads what the server can start, then creates the bot. A server that cannot be read still gets the bot, running
    /// like the main bot. `byPerson`: Create was pressed, so a bot that asked for this one is told now.
    @discardableResult func acceptHerdrBot(_ pending: PendingHerdrBot, manager: Bot, byPerson: Bool = true) async -> Bot? {
        var templates: [HerdrClient.Template] = [], offered: [HerdrClient.Template.Model] = []
        if pending.request.runtime != nil || pending.request.model != nil, let client = try? herdrClient(for: herdrServer(for: manager)) {
            templates = (try? await client.workspace().templates.filter { $0.error == nil }) ?? []
            let inherited = HerdrAgentReading.template(own: herdrTemplate(for: manager), shared: nil, in: templates).template
            if let template = HerdrBotRequest.template(for: pending.request.runtime, in: templates) ?? inherited { offered = (try? await client.models(for: template)) ?? template.models ?? [] }
        }
        let bot = createHerdrBot(pending, manager: manager, templates: templates, offered: offered)
        if byPerson, let bot { tellHerdrAsker(of: pending, HerdrBotRelay.decision(.created(bot.name), main: manager.name)) }
        return bot
    }

    // MARK: Bots the main bot created on its own decision

    /// The bots `manager` created unasked that the person has neither kept nor removed, newest last.
    func herdrUnaskedBots(of manager: Bot) -> [Bot] {
        let lead = manager.id.uuidString.lowercased() + "#"
        return (defaults.stringArray(forKey: Self.herdrUnaskedBotsKey) ?? []).compactMap { entry in
            guard entry.hasPrefix(lead) else { return nil }
            return bots.first { $0.id.uuidString.lowercased() == entry.dropFirst(lead.count) }
        }
    }

    /// Notes that `manager` created `bot` unasked, or (nil) that the person has settled it.
    func setHerdrUnasked(_ bot: Bot, by manager: Bot?) {
        let tail = "#" + bot.id.uuidString.lowercased()
        var entries = (defaults.stringArray(forKey: Self.herdrUnaskedBotsKey) ?? []).filter { !$0.hasSuffix(tail) }
        if let manager { entries.append(manager.id.uuidString.lowercased() + tail) }
        defaults.set(Array(entries.suffix(Self.herdrUnaskedBotsKept)), forKey: Self.herdrUnaskedBotsKey)
        objectWillChange.send()
    }

    /// The person is fine with the bot: it is no longer offered for removal.
    func keepHerdrBot(_ bot: Bot) { setHerdrUnasked(bot, by: nil) }

    /// The person does not want the bot the main bot created: it is deleted like any bot.
    func removeHerdrBot(_ bot: Bot, createdBy manager: Bot) {
        setHerdrUnasked(bot, by: nil)
        let name = bot.name
        delete(bot)
        notice(AppOnlyLine.botRemoved.render(name, manager.name), in: manager)
    }

    // MARK: When a reply ends

    /// The user messages a reply answers: those between it and the reply before it.
    func herdrTriggers(of reply: ChatMessage, in bot: Bot) -> [ChatMessage] {
        guard let index = bot.messages.firstIndex(where: { $0.id == reply.id }) else { return [] }
        let before = bot.messages[..<index]
        let start = before.lastIndex { $0.role == .assistant && $0.presentation == .text }.map { $0 + 1 } ?? before.startIndex
        return before[start...].filter { $0.role == .user }
    }

    /// The passed-on request this reply of the main bot answers, if it answers one.
    func herdrPassedOnRequest(answeredBy reply: ChatMessage, in bot: Bot) -> ChatMessage? {
        herdrTriggers(of: reply, in: bot).first { $0.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.request }
    }

    /// Called when a Herdr bot's turn in its own chat ends. The main bot's reply is settled (bots it decided are
    /// created, and a bot that asked is told the outcome); another bot's requests are passed on to the main bot,
    /// unless the reply answers a message the app itself passed on.
    func herdrReplyEnded(_ reply: ChatMessage, from bot: Bot, finished: Bool) {
        guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return }
        // An agent that answered is running; one whose turn failed is read again before the header says anything.
        herdrReadiness[bot.id] = finished ? .ready : nil
        let triggers = herdrTriggers(of: reply, in: bot)
        // What it wrote to other bots is delivered, and its answer to another bot's message goes back (`AppStore+HerdrMessages.swift`).
        let managed = bridgeCoordinates(bot)
        if !managed { herdrMessagesEnded(reply, from: bot, triggers: triggers, finished: finished) }
        if createsHerdrBots(bot) {
            let request = triggers.first { $0.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.request }
            guard finished else {
                // The asking bot is not sent a message for this: its person reads the line and may ask again.
                if let asker = herdrAsker(of: request) { notice(AppOnlyLine.botAskUnanswered.render(bot.name, asker.name, asker.name), in: asker) }
                return
            }
            let waiting = herdrRequests(in: reply, of: bot, askerID: herdrAsker(of: request)?.id)
            herdrSettling.formUnion(waiting.map(\.id))
            Task { await settleHerdrReply(reply, main: bot, waiting: waiting, request: request) }
        } else if !managed, finished, triggers.allSatisfy({ HerdrBotRelay.mayAsk(replyingTo: $0.metadata) }) {
            passOnHerdrAsks(HerdrBotAsk.asks(in: reply.content), from: bot)
        }
    }

    private func herdrAsker(of request: ChatMessage?) -> Bot? {
        request?.metadata[HerdrBotRelay.Key.asker].flatMap(UUID.init(uuidString:)).flatMap { id in bots.first { $0.id == id && $0.backend == .herdr } }
    }

    /// The main bot's finished reply: each bot it decided is created now (unless its person confirms every bot, or it
    /// has created `HerdrBotRelay.createLimit` already within the window); the rest wait for the person. When the
    /// reply answers another bot's request, that bot is told what came of it.
    func settleHerdrReply(_ reply: ChatMessage, main: Bot, waiting: [PendingHerdrBot], request: ChatMessage?) async {
        defer { herdrSettling.subtract(waiting.map(\.id)); objectWillChange.send() }
        var outcomes: [HerdrBotRelay.Outcome] = []
        for pending in waiting {
            if pending.taken { dismissHerdrBot(pending); outcomes.append(.taken(pending.request.name)); continue }
            guard pending.request.decided, !herdrAsksFirst(main), herdrAllowed(Self.herdrCreateTimesKey(main.id), limit: HerdrBotRelay.createLimit) else {
                outcomes.append(.waiting(pending.request.name)); continue
            }
            if let bot = await acceptHerdrBot(pending, manager: main, byPerson: false) {
                herdrCount(Self.herdrCreateTimesKey(main.id)); setHerdrUnasked(bot, by: main); outcomes.append(.created(bot.name))
            } else { outcomes.append(.waiting(pending.request.name)) }
        }
        guard let request, let asker = herdrAsker(of: request) else { save(); return }
        let asked = request.metadata[HerdrBotRelay.Key.name]
        let verdict = HerdrBotRelay.verdicts(in: reply.content, visible: SwarmhubBlock.visibleText(reply.content))
        outcomes += verdict.declines.map { .declined($0.name ?? asked, reason: $0.reason) }
        if outcomes.isEmpty, let words = verdict.words { outcomes.append(.answered(words.isEmpty ? "(nothing)" : words)) }
        herdrPassOn(HerdrBotRelay.answer(from: main.name, outcomes), to: asker, kind: HerdrBotRelay.outcome, asker: asker, name: asked)
        save()
    }

    /// Passes a bot's requests for new bots on to its server's main bot and says so in the asking bot's chat. With no
    /// main bot the asking bot is told, and the person reads what to do about it.
    func passOnHerdrAsks(_ asks: [HerdrBotAsk], from asker: Bot) {
        guard !asks.isEmpty else { return }
        let server = herdrServer(for: asker), times = Self.herdrAskTimesKey(asker.id)
        guard let main = herdrMainBot(on: server), main.id != asker.id else {
            notice(AppOnlyLine.botAskNoMain.render(asker.name, server.name), in: asker)
            if herdrAllowed(times, limit: HerdrBotRelay.askLimit) {
                herdrCount(times)
                herdrPassOn(HerdrBotRelay.noMain(asks[0]), to: asker, kind: HerdrBotRelay.outcome, asker: asker, name: asks[0].name)
            }
            return
        }
        for ask in asks {
            guard herdrAllowed(times, limit: HerdrBotRelay.askLimit) else {
                notice(AppOnlyLine.botAskTooMany.render(asker.name, ask.name, "\(HerdrBotRelay.askLimit)", "\(Int(HerdrBotRelay.window / 60))"), in: asker)
                continue
            }
            herdrCount(times)
            if herdrPassOn(HerdrBotRelay.request(from: asker.name, ask), to: main, kind: HerdrBotRelay.request, asker: asker, name: ask.name) {
                notice(AppOnlyLine.botAskPassedOn.render(asker.name, ask.name, main.name), in: asker)
            } else {
                notice(AppOnlyLine.botAskNotPassedOn.render(asker.name, ask.name, main.name), in: asker)
            }
        }
    }

    /// Tells the bot that asked for `pending` what the person decided.
    private func tellHerdrAsker(of pending: PendingHerdrBot, _ text: String) {
        guard let asker = pending.askerID.flatMap({ id in bots.first { $0.id == id && $0.backend == .herdr } }) else { return }
        herdrPassOn(text, to: asker, kind: HerdrBotRelay.outcome, asker: asker, name: pending.request.name)
    }

    /// Puts a message the person did not write into `bot`'s chat, marked as passed on, and has its agent answer it: at
    /// once when the bot is idle, otherwise as its next message when the running answer ends.
    /// `extra`: what else the message carries (an exchange between bots: `HerdrBotRelay.ExchangeKey`).
    @discardableResult func herdrPassOn(_ text: String, to bot: Bot, kind: String, asker: Bot, name: String?, extra: [String: String] = [:]) -> Bool {
        var metadata = extra.merging([HerdrBotRelay.Key.kind: kind, HerdrBotRelay.Key.asker: asker.id.uuidString.lowercased()]) { _, own in own }
        metadata[HerdrBotRelay.Key.name] = name
        if isIdle(bot) { return send(text: text, bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true, metadata: metadata) }
        let message = ChatMessage(role: .user, content: text, metadata: metadata)
        bot.messages.append(message)
        return waitForTurn(message, in: bot, reason: SteerCopy.afterTurn)
    }

    /// The caption over a message the app passed on, so it does not read as the person's own.
    func herdrRelayCaption(_ message: ChatMessage) -> String? {
        guard message.role == .user, let kind = message.metadata[HerdrBotRelay.Key.kind] else { return nil }
        if let exchange = herdrExchangeCaption(message) { return exchange }
        // The outcome is written to the asking bot ("the bot you asked for now exists"), so the caption says who was told.
        guard kind == HerdrBotRelay.request else {
            let told = bots.first { bot in bot.messages.contains { $0 === message } }?.name
            return told.map { "\(AppConstants.name) told \($0)" } ?? "About the bot it asked for"
        }
        let asker = message.metadata[HerdrBotRelay.Key.asker].flatMap(UUID.init(uuidString:)).flatMap { id in bots.first { $0.id == id }?.name }
        return "\(asker ?? "Another bot") asks for a new bot"
    }

    /// A message the app put into a chat for the agent, as the chat shows it: who it is from, in a few words, and
    /// only the part that is someone's words (`HerdrPassedOn`). nil for what the person wrote. `id` is the message's,
    /// which is what the chat remembers an unfolded card by.
    struct PassedOnRow { let id: UUID; let title: String; let sender: Bot?; let shown: HerdrPassedOn }
    func herdrPassedOnRow(_ message: ChatMessage) -> PassedOnRow? {
        if let sent = herdrSentRow(message) { return sent }
        guard let title = herdrRelayCaption(message), let kind = message.metadata[HerdrBotRelay.Key.kind] else { return nil }
        // The bot whose words these are: the one that asked or wrote, or the one whose answer came back.
        let key = kind == HerdrBotRelay.answer ? HerdrBotRelay.ExchangeKey.from : HerdrBotRelay.Key.asker
        let sender = kind == HerdrBotRelay.request || kind == HerdrBotRelay.message || kind == HerdrBotRelay.answer
            ? message.metadata[key].flatMap { id in bots.first { $0.id.uuidString.lowercased() == id.lowercased() } } : nil
        return PassedOnRow(id: message.id, title: title, sender: sender, shown: HerdrPassedOn(message.content))
    }

    /// The other side of a message between bots, in the chat of the bot that wrote it: the app's line "Infra wrote
    /// to Jarvis: “…”" as the same kind of card, in the writer's own colour. The line is read as it was stored, so
    /// lines written by an older version fold too.
    func herdrSentRow(_ message: ChatMessage) -> PassedOnRow? {
        guard message.role == .system, message.metadata[AppOnlyLine.key] != nil,
              let parts = HerdrMessageLine.sent.values(in: message.content), parts.count == 3 else { return nil }
        return PassedOnRow(id: message.id, title: HerdrMessageLine.sentTitle(to: parts[1]), sender: bots.first { $0.name == parts[0] }, shown: HerdrPassedOn(words: parts[2]))
    }

    /// The person did not write this row: the app did, for the agent (a passed-on message, or the note that starts
    /// the main bot's introduction).
    func isAppWritten(_ message: ChatMessage) -> Bool {
        message.role == .user && (message.metadata[HerdrBotRelay.Key.kind] != nil || message.metadata[HerdrIntro.Key.kind] != nil)
    }

    // MARK: How often

    static func herdrAskTimesKey(_ botID: UUID) -> String { "herdrBotAsks.\(botID.uuidString.lowercased())" }
    static func herdrCreateTimesKey(_ botID: UUID) -> String { "herdrBotCreations.\(botID.uuidString.lowercased())" }

    private func herdrTimes(_ key: String) -> [Double] { (defaults.array(forKey: key) as? [Double]) ?? [] }
    func herdrAllowed(_ key: String, limit: Int) -> Bool { HerdrBotRelay.allowed(herdrTimes(key), limit: limit, now: now().timeIntervalSinceReferenceDate) }
    func herdrCount(_ key: String) {
        let moment = now().timeIntervalSinceReferenceDate
        defaults.set(HerdrBotRelay.recent(herdrTimes(key), now: moment) + [moment], forKey: key)
    }
}

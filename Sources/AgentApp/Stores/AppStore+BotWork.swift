import Foundation

/// P42: the live cards. One poller per watched session reads it (2 s, 10 s after a quiet minute, at most 30 min) and
/// draws its last exchange into the bot's chat as a card: who woke it, the request, the steps as they unfold, the reply.
/// Reads only (no turn slots, so P39's limits don't apply); none for a bot whose connection is down.
@MainActor final class BotWorkCenter: ObservableObject {
    struct Key: Hashable { var bot: UUID; var target: String }
    /// A run going on now: what started it and when it last changed.
    struct Live: Equatable { var origin: BotWorkOrigin; var startedAt: Date; var session: String? }

    /// Bots working on something the user didn't type (sidebar, chat header, avatar).
    @Published var live: [Key: Live] = [:]
    var pollers: [Key: Task<Void, Never>] = [:]
    /// Off in tests and renders unless switched on (with an injected sleep and source).
    var autoStart = true
    /// Recipients whose first thread list since launch was checked for runs still going.
    var checkedSinceLaunch: Set<UUID> = []
    /// Tests: the session reads instead of the bot's backend.
    var rowsOverride: (@MainActor (Bot, String) async throws -> [BackendMessage])?
    var sessionsOverride: (@MainActor (Bot, String) async throws -> [BotSessionRow])?
}

extension AppStore {
    // MARK: Reads

    func botWorkRows(_ bot: Bot, session: String) async throws -> [BackendMessage] {
        if let read = botWork.rowsOverride { return try await read(bot, session) }
        guard let backend = try backend(for: bot) as? HermesBackend else { return [] }
        return try await backend.workRows(sessionID: session)
    }

    func botWorkSessions(_ bot: Bot, source: String) async throws -> [BotSessionRow] {
        if let read = botWork.sessionsOverride { return try await read(bot, source) }
        guard let backend = try backend(for: bot) as? HermesBackend else { return [] }
        return try await backend.sessionRows(source: source)
    }

    /// A connection SwarmHub can't reach now: no key, or the bot's last thread list failed.
    func isConnectionDown(_ bot: Bot) -> Bool { needsKey(bot) || botMessages.errors[bot.id] != nil }

    // MARK: State

    /// What `bot` works on that the user didn't start, newest first.
    func botWorkLive(for bot: Bot) -> BotWorkCenter.Live? {
        botWork.live.filter { $0.key.bot == bot.id }.values.max { $0.startedAt < $1.startedAt }
    }

    /// "Working… · for Jarvis" while a card of this bot is live.
    func botWorkLine(for bot: Bot) -> String? {
        botWorkLive(for: bot).map { BotWorkCopy.working($0.origin, name: displayName(forProfile:)) }
    }

    /// The line the sidebar and the header show for work the user didn't start: a live card, else a sender's running
    /// bot-msg step (P41).
    func workingForOthersLine(for bot: Bot) -> String? { botWorkLine(for: bot) ?? incomingBotMessageLine(for: bot) }

    // MARK: Watch

    /// Starts watching `target` in `bot` (once per session): `after` skips an older exchange still at the end of the
    /// session; `showFinished` false only reopens a run still going (restart), never a finished one.
    func watchBotWork(_ bot: Bot, target: BotWorkTarget, origin: BotWorkOrigin, after: Date? = nil, showFinished: Bool = true) {
        let key = BotWorkCenter.Key(bot: bot.id, target: target.key)
        guard botWork.autoStart, bot.backend == .hermes, !bot.isReadOnlyArchive, botWork.pollers[key] == nil, !isConnectionDown(bot) else { return }
        let sleep = botWorkSleep
        botWork.pollers[key] = Task { [weak self] in
            await self?.followBotWork(bot, key: key, target: target, origin: origin, after: after, showFinished: showFinished, sleep: sleep)
            self?.botWork.pollers[key] = nil
            if self?.botWork.live.removeValue(forKey: key) != nil { self?.objectWillChange.send() }
        }
    }

    private func followBotWork(_ bot: Bot, key: BotWorkCenter.Key, target: BotWorkTarget, origin: BotWorkOrigin, after: Date?, showFinished: Bool,
                               sleep: @Sendable (Duration) async throws -> Void) async {
        var session: String? = if case .session(let id) = target { id } else { nil }
        let start = now()
        // A step's watch waits for its own request: exchanges already on cards are older ones.
        let older = after == nil ? [] : Set(session.map { botWorkCards(in: bot, session: $0).compactMap { $0.metadata[BotWorkKey.requestID] } } ?? [])
        var lastSignature: String?, lastChange = start, failures = 0
        while !Task.isCancelled, !isConnectionDown(bot), now().timeIntervalSince(start) < BotWorkSchedule.limit {
            do {
                if session == nil, case .newest(let source, _, _) = target { session = target.pick(try await botWorkSessions(bot, source: source)) }
                if let session, let turn = BotWorkReader.lastTurn(try await botWorkRows(bot, session: session), after: after), !older.contains(turn.requestID) {
                    if turn.signature != lastSignature {
                        lastSignature = turn.signature; lastChange = now()
                        if !showFinished, turn.finished, botWorkCard(in: bot, session: session, requestID: turn.requestID) == nil { return }
                        applyBotWork(turn, bot: bot, session: session, origin: turn.origin ?? origin, key: key, start: start)
                    }
                    if turn.finished { return }
                }
                failures = 0
            } catch {
                failures += 1
                if failures >= BotWorkSchedule.failures { break }
            }
            do { try await sleep(BotWorkSchedule.interval(sinceChange: now().timeIntervalSince(lastChange))) } catch { break }
        }
        // Stopped before the reply (30 min, connection down, cancelled): the card stops moving and says so.
        if let session, let card = botWorkCards(in: bot, session: session).last, card.isStreaming {
            card.isStreaming = false
            if card.metadata[BotWorkKey.reply] == nil, now().timeIntervalSince(start) >= BotWorkSchedule.limit { card.metadata[BotWorkKey.reply] = BotWorkCopy.stopped }
            objectWillChange.send(); save()
        }
    }

    /// The cards of one session in `bot`'s chat (P41 arrival lines included), oldest first.
    func botWorkCards(in bot: Bot, session: String) -> [ChatMessage] {
        bot.messages.filter { $0.presentation == .botMessage && $0.metadata[BotMessageKey.session] == session }
    }

    /// The card showing one exchange; an arrival line not tied to an exchange yet counts as the newest one's.
    func botWorkCard(in bot: Bot, session: String, requestID: String) -> ChatMessage? {
        let cards = botWorkCards(in: bot, session: session)
        if let exact = cards.last(where: { $0.metadata[BotWorkKey.requestID] == requestID }) { return exact }
        return cards.last.flatMap { $0.metadata[BotWorkKey.requestID] == nil ? $0 : nil }
    }

    /// Draws `turn` into its card (a new one for a new exchange): the request, the steps so far, the reply; the card
    /// streams and the bot works until the reply.
    func applyBotWork(_ turn: BotWorkTurn, bot: Bot, session: String, origin: BotWorkOrigin, key: BotWorkCenter.Key, start: Date) {
        let card: ChatMessage
        if let existing = botWorkCard(in: bot, session: session, requestID: turn.requestID) {
            card = existing
        } else {
            card = ChatMessage(role: .system, content: botWorkTitle(origin, recipient: bot), createdAt: turn.startedAt ?? now(), presentation: .botMessage,
                               metadata: [BotMessageKey.session: session, BotMessageKey.to: profile(of: bot)])
            if let profile = origin.profile { card.metadata[BotMessageKey.from] = profile }
            bot.messages.append(card)
            if let sender = origin.profile, openBotThread != BotThreadKey(from: sender, to: profile(of: bot)) { botMessages.unread[bot.id, default: []].insert(session) }
        }
        card.content = botWorkTitle(origin, recipient: bot)
        card.metadata[BotWorkKey.origin] = origin.raw; card.metadata[BotWorkKey.requestID] = turn.requestID
        card.metadata[BotWorkKey.request] = String(turn.request.prefix(BotMessageCall.textLimit))
        card.metadata[BotWorkKey.reply] = turn.reply.map { String($0.prefix(BotMessageCall.textLimit)) }
        card.activity = turn.activity
        card.isStreaming = !turn.finished
        if turn.finished { botWork.live[key] = nil } else { botWork.live[key] = .init(origin: origin, startedAt: turn.startedAt ?? start, session: session) }
        objectWillChange.send(); save()
    }

    /// The card's first line: P41's "Jarvis wrote to Infra" for a bot's message, else who woke it.
    func botWorkTitle(_ origin: BotWorkOrigin, recipient: Bot) -> String {
        if case .bot(let sender) = origin { return BotMessageCopy.arrival(from: displayName(forProfile: sender), to: recipient.name) }
        return BotWorkCopy.wokenBy(origin, name: displayName(forProfile:))
    }

    /// A sender's bot-msg step just started: its recipient's card goes live at once (P41 showed only "Working…").
    func noteStartedBotMessageSteps(before: ToolActivity?, after: ToolActivity, sender: Bot) {
        let known = Set((before?.steps ?? []).map(\.startedAt))
        for step in after.steps where step.isRunning && !known.contains(step.startedAt) {
            guard let call = step.botMessage, let recipient = bot(forProfile: call.to), recipient.id != sender.id else { continue }
            let from = call.from ?? profile(of: sender)
            // A minute of slack for the box's clock; older exchanges are told apart by their cards.
            watchBotWork(recipient, target: botWorkTarget(for: call, from: from, at: step.startedAt), origin: .bot(from), after: step.startedAt.addingTimeInterval(-60))
        }
    }

    /// Where a call's exchange lands in the recipient: its `swarmhub-from-<sender>` session.
    func botWorkTarget(for call: BotMessageCall, from: String, at start: Date) -> BotWorkTarget {
        .session(BotThreadKey.sessionID(from: from))
    }

    /// Stops every poller (store teardown).
    func stopBotWork() {
        botWork.pollers.values.forEach { $0.cancel() }
        botWork.pollers = [:]; botWork.live = [:]
    }
}

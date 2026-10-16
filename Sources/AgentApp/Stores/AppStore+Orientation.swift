import Foundation

/// P49: memory only. The bots whose orientation is being checked or sent now, and when the last retry pass ran.
struct OrientationRunState {
    static let retryEvery: TimeInterval = 60, giveUpAfter: TimeInterval = 24 * 3600
    var inFlight: Set<UUID> = []
    var lastPass: Date?
}

enum OrientationCopy {
    /// Settings → Advanced → Orientation (on unless switched off).
    static let enabledKey = "orientationEnabled"
    /// The collapsed user row of the orientation turn.
    static let display = "Orientation"
    static func gaveUp(_ name: String) -> String { "\(name) could not be reached for 24 h, so it was not given an orientation." }
}

/// P49: a bot that was really created (the manager's `createBot`, a Grok import that makes a new bot) orients itself once:
/// SwarmHub sends one first turn into its Bot Chat when it is ready (connected, key present, Bot Chat titled per P46), on
/// the normal turn path (P39: it waits like any message). Unreachable: it waits for the next connect and is given up after
/// 24 h with one quiet line. Bots that already existed and are only connected (setup scan, add-from-box, discovery,
/// OpenClaw, restore, reconnect, key change) never get one: `Bot.init` and an old store.json mark them oriented.
extension AppStore {
    var orientationEnabled: Bool { defaults.object(forKey: OrientationCopy.enabledKey) as? Bool ?? true }

    /// True while the bot's orientation waits to be sent.
    func orientationPending(_ bot: Bot) -> Bool { bot.orientedAt == nil && bot.orientationQueuedAt != nil }

    /// Called by the two creation paths only. With orientation off the bot simply counts as oriented.
    func queueOrientation(_ bot: Bot) {
        guard orientationEnabled, !bot.isReadOnlyArchive, !bot.isDemo else { return }
        bot.orientedAt = nil; bot.orientationQueuedAt = now()
        save(); scheduleOrientationPass()
    }

    /// The real app starts a pass at once (tests call `orientationPass()` themselves).
    func scheduleOrientationPass() {
        guard botInfo.autoLoad else { return }
        Task { [weak self] in await self?.orientationPass() }
    }

    /// The routine poll's tick: a retry pass at most once a minute while an orientation waits.
    func orientationPassIfDue() async {
        guard bots.contains(where: orientationPending) else { return }
        if let last = orientationRun.lastPass, now().timeIntervalSince(last) < OrientationRunState.retryEvery { return }
        await orientationPass()
    }

    /// One try for every bot whose orientation waits.
    func orientationPass() async {
        orientationRun.lastPass = now()
        guard orientationEnabled else { return }
        for bot in bots where orientationPending(bot) { await orient(bot) }
    }

    func orient(_ bot: Bot) async {
        guard orientationPending(bot), let queued = bot.orientationQueuedAt, !orientationRun.inFlight.contains(bot.id) else { return }
        if now().timeIntervalSince(queued) >= OrientationRunState.giveUpAfter {
            bot.orientedAt = now(); bot.orientationQueuedAt = nil
            bot.messages.append(ChatMessage(role: .system, content: OrientationCopy.gaveUp(bot.name)))
            objectWillChange.send(); save(); return
        }
        guard !bot.isReadOnlyArchive, !bot.isGrokHistoryOnly, !needsKey(bot), !turns.pathDown, isIdle(bot), !hasWaitingTurn(in: bot) else { return }
        orientationRun.inFlight.insert(bot.id); defer { orientationRun.inFlight.remove(bot.id) }
        guard await orientationReady(bot), orientationPending(bot), isIdle(bot), !hasWaitingTurn(in: bot) else { return }
        let metadata = [AutomationKey.display: OrientationCopy.display, AutomationKey.orientation: "1"]
        guard send(text: orientationPrompt(for: bot), bot: bot, conversation: bot, replyToID: nil, waitWhenFull: true, metadata: metadata) else { return }
        bot.orientedAt = now(); bot.orientationQueuedAt = nil
        objectWillChange.send(); save()
    }

    /// The bot answers, and a Hermes bot's main session (when it has one) is titled "Bot Chat" (P46). A brand-new bot has
    /// no session yet: the orientation turn opens it, and the live-rows read titles it on its first answer, as for any bot.
    /// A title conflict does not hold orientation back (the chat already shows P46's "Use this chat" line).
    func orientationReady(_ bot: Bot) async -> Bool {
        guard let backend = try? backend(for: bot), (try? await backend.testConnection()) != nil else { return false }
        if backend is HermesBackend, bot.hermesSessionID != nil, !hasBotChat(bot), await ensureBotChat(bot) != nil {
            return botChatConflict(bot) != nil
        }
        return true
    }

    func orientationPrompt(for bot: Bot) -> String {
        "Hi \(bot.name), you were just created in SwarmHub. Greet Konrad in one line and say what you will do here."
    }
}

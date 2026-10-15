import Foundation

/// P34: what SwarmHub knows about bot-to-bot threads beyond the chats themselves: each connected bot's `From <bot>`
/// sessions from its last session list, the arrivals not yet opened (sidebar badge), and loaded thread lines.
@MainActor final class BotMessageCenter: ObservableObject {
    /// Recipient bot → its thread rows from the last session list.
    @Published var rows: [UUID: [BotThreadRow]] = [:]
    /// Recipient bot → thread sessions with an arrival not opened yet.
    @Published var unread: [UUID: Set<String>] = [:]
    /// Threads read from the recipient (oldest first).
    @Published var loaded: [BotThreadKey: [BotThreadLine]] = [:]
    /// P41: recipient (`markKey`: connection and profile) → session id → mark, saved with the store so a restart does
    /// not swallow a change; absent until the recipient's first list ever.
    var marks: [String: [String: String]] = [:]
    /// P41: the first list ever treats threads changed this recently as new.
    var firstListWindow: TimeInterval = 86_400
    /// P41: recipient bot → why its last session list failed (the Info panel's quiet line); cleared by the next success.
    @Published var errors: [UUID: String] = [:]
    var lastPoll: [UUID: Date] = [:]
    var autoLoad = true
    var pollInterval: TimeInterval = 20
}

enum BotMessageKey {
    static let from = "botMessage.from", to = "botMessage.to", session = "botMessage.session"
}

extension AppStore {
    // MARK: Who is who

    func profile(of bot: Bot) -> String { bot.hermesProfile ?? "default" }

    func bot(forProfile profile: String) -> Bot? {
        bots.first { $0.backend == .hermes && !$0.isReadOnlyArchive && ($0.hermesProfile ?? "default") == profile }
    }

    func displayName(forProfile profile: String) -> String { bot(forProfile: profile)?.name ?? profile }

    /// P41: where a recipient's seen marks are kept: its connection and profile.
    func botMessageMarkKey(_ recipient: Bot) -> String { connection(of: recipient) + "|" + profile(of: recipient) }

    /// A recipient whose thread SwarmHub can read: a connected Hermes bot with its key.
    func readableRecipient(_ key: BotThreadKey) -> Bot? {
        guard let bot = bot(forProfile: key.to), !needsKey(bot) else { return nil }
        return bot
    }

    // MARK: Threads

    /// Every bot-msg step in a bot's replies (oldest first) with the call it made.
    func botMessageSteps(of bot: Bot) -> [(step: ToolStep, call: BotMessageCall)] {
        bot.messages.flatMap { message in (message.activity?.steps ?? []).compactMap { step in step.botMessage.map { (step, $0) } } }
    }

    /// The thread lines SwarmHub has without asking anyone: the loaded thread, else the sender's steps (text, reply).
    func knownThreadLines(_ key: BotThreadKey) -> [BotThreadLine] {
        if let loaded = botMessages.loaded[key], !loaded.isEmpty { return loaded }
        guard let sender = bot(forProfile: key.from) else { return [] }
        return botMessageSteps(of: sender).filter { $0.call.to == key.to }.enumerated().flatMap { index, item -> [BotThreadLine] in
            var lines = [BotThreadLine(id: "s\(index)", author: key.from, text: item.call.text, date: item.step.startedAt)]
            if let reply = item.call.reply, !item.call.noWait { lines.append(BotThreadLine(id: "r\(index)", author: key.to, text: reply, date: item.step.finishedAt)) }
            return lines
        }
    }

    /// Reads the thread with the recipient's own key; leaves what is known in place when it cannot.
    func loadThread(_ key: BotThreadKey) async {
        guard let recipient = readableRecipient(key), let backend = try? backend(for: recipient),
              let messages = try? await backend.loadMessages(sessionID: key.sessionID) else { return }
        let lines = messages.enumerated().compactMap { index, message -> BotThreadLine? in
            switch message.role {
            case "user": BotThreadLine(id: "m\(index)", author: key.from, text: BotMessageCall.strippingHeader(message.content).text, date: message.createdAt)
            case "assistant": BotThreadLine(id: "m\(index)", author: key.to, text: message.content, date: message.createdAt)
            default: nil
            }
        }
        if !lines.isEmpty, botMessages.loaded[key] != lines { botMessages.loaded[key] = lines }
    }

    func openThread(_ key: BotThreadKey) {
        openBotThread = key
        if let recipient = bot(forProfile: key.to) { clearBotMessageBadge(recipient, session: key.sessionID) }
    }

    /// Threads involving `bot`, newest first: what it sent (its steps), what others sent it (their steps and its
    /// session list).
    func threadSummaries(for bot: Bot) -> [BotThreadSummary] {
        let me = profile(of: bot)
        return allBotThreads().filter { $0.key.from == me || $0.key.to == me }
    }

    /// Every thread SwarmHub knows of, newest first.
    func allBotThreads() -> [BotThreadSummary] {
        var byKey: [BotThreadKey: BotThreadSummary] = [:]
        func add(_ key: BotThreadKey, line: String, date: Date?) {
            if let old = byKey[key], (old.date ?? .distantPast) >= (date ?? .distantPast) { return }
            byKey[key] = BotThreadSummary(key: key, lastLine: line, date: date)
        }
        for sender in bots where sender.backend == .hermes {
            for item in botMessageSteps(of: sender) {
                let key = BotThreadKey(from: profile(of: sender), to: item.call.to)
                add(key, line: item.call.reply ?? item.call.text, date: item.step.finishedAt ?? item.step.startedAt)
            }
        }
        for (recipientID, rows) in botMessages.rows {
            guard let recipient = bots.first(where: { $0.id == recipientID }) else { continue }
            for row in rows { add(BotThreadKey(from: row.sender, to: profile(of: recipient)), line: row.preview ?? "", date: row.updatedAt) }
        }
        for (key, lines) in botMessages.loaded { if let last = lines.last { add(key, line: last.text, date: last.date) } }
        return byKey.values.sorted { ($0.date ?? .distantPast, $0.key.id) > ($1.date ?? .distantPast, $1.key.id) }
    }

    // MARK: Arrivals (D6)

    /// One session-list request per connected Hermes bot, at most every `pollInterval` (runs on the routine poll tick).
    func pollBotMessagesOnce(now: Date = .now) async {
        guard botMessages.autoLoad else { return }
        for bot in bots where bot.backend == .hermes && !bot.isReadOnlyArchive && !needsKey(bot) {
            if let last = botMessages.lastPoll[bot.id], now.timeIntervalSince(last) < botMessages.pollInterval { continue }
            botMessages.lastPoll[bot.id] = now
            await checkBotMessages(for: bot)
        }
    }

    /// Lists `recipient`'s threads; a new or changed one is an arrival. A failure is kept as one quiet line for the
    /// bot's Info panel (P41) instead of being dropped.
    func checkBotMessages(for recipient: Bot, expecting sender: String? = nil) async {
        do {
            guard let backend = try backend(for: recipient) as? HermesBackend else { return }
            let rows = try await backend.botThreadRows()
            if botMessages.errors[recipient.id] != nil { botMessages.errors[recipient.id] = nil }
            applyBotThreadRows(rows, recipient: recipient, expecting: sender)
        } catch {
            let text = error.localizedDescription
            if botMessages.errors[recipient.id] != text { botMessages.errors[recipient.id] = text }
        }
    }

    /// The first list ever (no saved marks) records, except threads changed in the last `firstListWindow` and the one a
    /// sender just wrote to (`expecting`); after that any changed mark is an arrival. Marks are saved with the store.
    func applyBotThreadRows(_ rows: [BotThreadRow], recipient: Bot, expecting sender: String? = nil) {
        let markKey = botMessageMarkKey(recipient), baseline = botMessages.marks[markKey]
        let recent = now().addingTimeInterval(-botMessages.firstListWindow)
        var marks = baseline ?? [:]
        for row in rows {
            let old = marks[row.sessionID]
            marks[row.sessionID] = row.mark
            let arrived = baseline == nil ? row.sender == sender || (row.updatedAt.map { $0 >= recent } ?? false) : old != row.mark
            if arrived { postArrival(from: row.sender, recipient: recipient, session: row.sessionID) }
        }
        if botMessages.rows[recipient.id] != rows { botMessages.rows[recipient.id] = rows }
        if baseline != marks { botMessages.marks[markKey] = marks; save() }
    }

    /// "<avatar> Jarvis wrote to Infra · Open conversation" in the recipient's chat (consecutive arrivals from one
    /// thread share a line), and the sidebar badge unless that exact conversation is on screen (P41).
    func postArrival(from sender: String, recipient: Bot, session: String) {
        let text = BotMessageCopy.arrival(from: displayName(forProfile: sender), to: recipient.name)
        if let last = recipient.messages.last, last.presentation == .botMessage, last.metadata[BotMessageKey.session] == session {
            last.content = text
        } else {
            recipient.messages.append(ChatMessage(role: .system, content: text, createdAt: now(), presentation: .botMessage,
                                                  metadata: [BotMessageKey.from: sender, BotMessageKey.to: profile(of: recipient), BotMessageKey.session: session]))
        }
        if openBotThread != BotThreadKey(from: sender, to: profile(of: recipient)) { botMessages.unread[recipient.id, default: []].insert(session) }
        objectWillChange.send(); save()
    }

    func hasBotMessageBadge(_ bot: Bot) -> Bool { !(botMessages.unread[bot.id] ?? []).isEmpty }

    /// Opening the conversation clears its arrival (P41: opening the chat alone no longer does).
    func clearBotMessageBadge(_ bot: Bot, session: String? = nil) {
        guard var sessions = botMessages.unread[bot.id], !sessions.isEmpty else { return }
        if let session { sessions.remove(session) } else { sessions.removeAll() }
        botMessages.unread[bot.id] = sessions.isEmpty ? nil : sessions
        objectWillChange.send()
    }

    /// A sender's bot-msg steps that just ended: check their recipients now instead of on the next tick.
    func noteEndedBotMessageSteps(before: ToolActivity?, after: ToolActivity, sender: Bot) {
        let wasRunning = Set((before?.steps ?? []).filter { $0.isRunning && $0.botMessage != nil }.map(\.startedAt))
        guard !wasRunning.isEmpty else { return }
        for step in after.steps where !step.isRunning && wasRunning.contains(step.startedAt) {
            guard let call = step.botMessage, let recipient = bot(forProfile: call.to), !needsKey(recipient) else { continue }
            let from = profile(of: sender)
            Task { await checkBotMessages(for: recipient, expecting: from) }
        }
    }
}

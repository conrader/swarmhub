import Foundation

/// P51: one row the chat shows as a single folded line instead of its raw text: protocol the bots and SwarmHub exchange.
/// Display only — `content` is never rewritten, so search (P41/FTS) and the box keep the original.
struct TechnicalFold: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `[[SWARMHUB_APP_REQUEST_<uuid>]] {…}` (assistant) and `SwarmHub app result (untrusted data…)` (user).
        case appRequest, appResult
        /// `[IMPORTANT: The user has invoked the "<skill>" skill …]` + the skill's text (user).
        case skill
        /// `[Message from X via SwarmHub]` / `[Reply from X via SwarmHub]` (user), and P42's exchange card.
        case botMessage, botReply
        /// `[OUT-OF-BAND USER MESSAGE …]` still wrapped, `[Cronjob "<name>" output …]`, and one-word acks.
        case outOfBand, routineOutput, ack
        /// A row Hermes wrote itself (`HermesInternalNote`): an async delegation finishing, a process notification, ….
        case internalNote
    }
    var kind: Kind; var summary: String
    /// The raw text unfold shows and "Copy original" copies (an app pair: request, blank line, result).
    var original: String
    /// An app request's result row, folded into this line (the chat no longer lists it).
    var partnerID: UUID? = nil
    /// The other bot of a bot-to-bot line (its avatar and Open conversation).
    var profile: String? = nil
}

/// P52: metadata of the system line `.appUsed` writes (`AppStore.consumeTurn`).
enum TechnicalKey { static let appRequest = "app.request", appResult = "app.result" }

/// What a fold's summary names: this chat's bot and the names of other bots, apps and accounts.
struct TechnicalContext {
    var botName: String
    var displayName: (String) -> String = { $0 }
    var appName: (String) -> String = { ComposioToolkit.displayName($0) }
    /// P48: an account's name for its id (nil keeps what the bot wrote).
    var accountName: (String) -> String? = { _ in nil }
}

/// The folds of one chat's shown rows (oldest first) and the result rows they absorbed.
struct TechnicalLayout {
    var folds: [UUID: TechnicalFold] = [:]
    var absorbed: Set<UUID> = []
    func visible(_ rows: [ChatMessage]) -> [ChatMessage] { absorbed.isEmpty ? rows : rows.filter { !absorbed.contains($0.id) } }
}

enum TechnicalRow {
    static let firstLineLimit = 120
    nonisolated static let appRequest = try! NSRegularExpression(pattern: #"\A\s*\[\[SWARMHUB_APP_REQUEST_[0-9A-Fa-f-]{36}\]\]"#)
    static let skillHeader = try! NSRegularExpression(pattern: #"\A\s*\[IMPORTANT: The user has invoked the "([A-Za-z0-9._:-]{1,80})" skill[^\]\n]*\]"#)
    static let ackWord = try! NSRegularExpression(pattern: #"\A\s*[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\s*\z"#)

    static func layout(_ rows: [ChatMessage], context: (ChatMessage) -> TechnicalContext) -> TechnicalLayout {
        var layout = TechnicalLayout()
        for (index, row) in rows.enumerated() where !layout.absorbed.contains(row.id) {
            let next = rows.indices.contains(index + 1) ? rows[index + 1] : nil
            guard let fold = classify(row, next: next, isLast: next == nil, context: context(row)) else { continue }
            layout.folds[row.id] = fold
            if let partner = fold.partnerID { layout.absorbed.insert(partner) }
        }
        return layout
    }

    /// The fold of one row; `next` is the row shown after it (an app request's result), `isLast` whether nothing follows.
    static func classify(_ message: ChatMessage, next: ChatMessage? = nil, isLast: Bool = false, context: TechnicalContext) -> TechnicalFold? {
        if message.presentation == .botMessage { return exchange(message, context: context) }
        // P52: an app read SwarmHub ran on its own: the request and the result's start ride on the system line.
        if message.role == .system, let request = message.metadata[TechnicalKey.appRequest] {
            let result = message.metadata[TechnicalKey.appResult]
            return TechnicalFold(kind: .appRequest, summary: TechnicalApps.summary(request: request, result: result, waiting: false, context: context),
                                 original: result.map { request + "\n\n" + $0 } ?? request)
        }
        guard message.presentation == .text, message.role != .system else { return nil }
        let text = message.content
        if message.role == .assistant, isAppRequest(text) {
            let result = next.flatMap { $0.role == .user && isAppResult($0.content) ? $0 : nil }
            return TechnicalFold(kind: .appRequest, summary: TechnicalApps.summary(request: text, result: result?.content, waiting: isLast, context: context),
                                 original: result.map { text + "\n\n" + $0.content } ?? text, partnerID: result?.id)
        }
        if message.role == .user, isAppResult(text) {
            return TechnicalFold(kind: .appResult, summary: TechnicalApps.summary(result: text, context: context), original: text)
        }
        if let ack = ack(text) { return TechnicalFold(kind: .ack, summary: ack, original: text) }
        guard message.role == .user else { return nil }
        if let note = HermesInternalNote.summary(message) { return TechnicalFold(kind: .internalNote, summary: note, original: text) }
        if let skill = match(skillHeader, text) {
            let label = wokenLabel(message).map { $0 + " · uses skill " } ?? "Uses skill "
            return TechnicalFold(kind: .skill, summary: label + skill, original: text)
        }
        if let (origin, body) = BotWorkOrigin.header(text), let profile = origin.profile {
            return botLine(origin, profile: profile, to: context.botName, body: body, original: text, context: context)
        }
        if let inner = OutOfBandMessage.unwrap(text) {
            return TechnicalFold(kind: .outOfBand, summary: OutOfBandMessage.label(botName: context.botName) + ": " + firstLine(inner), original: text)
        }
        if let job = CronDeliveryRow.jobName(text) {
            let label = message.metadata[AutomationKey.display] ?? (job.lowercased().contains("heartbeat") ? "Heartbeat" : "Routine: \(job)")
            return TechnicalFold(kind: .routineOutput, summary: label, original: text)
        }
        return nil
    }

    nonisolated static func isAppRequest(_ text: String) -> Bool {
        appRequest.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    nonisolated static func isAppResult(_ text: String) -> Bool {
        text.drop { $0.isWhitespace }.hasPrefix(ConnectedAppsChat.resultPrefix.trimmingCharacters(in: .newlines))
    }

    /// The line a sidebar preview, a notification or a reply quote uses for a row: its fold, else the visible text, else
    /// the summary of its ```swarmhub block (a reply that is only a block).
    static func displayLine(_ message: ChatMessage, next: ChatMessage? = nil, context: TechnicalContext) -> String {
        if let fold = classify(message, next: next, context: context) { return fold.summary }
        guard message.role == .assistant else { return message.metadata[AutomationKey.display] ?? message.content }
        let visible = SwarmhubBlock.visibleText(message.finalText)
        if visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let block = SwarmhubSummary.lines(in: message.finalText).last { return block.summary }
        return visible
    }

    /// The first non-empty line, whitespace collapsed, cut at `firstLineLimit`.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.first { !$0.isEmpty } ?? ""
        return line.count > firstLineLimit ? String(line.prefix(firstLineLimit - 1)) + "…" : line
    }

    /// P46's label for a row SwarmHub or the box woke the bot with: "Heartbeat", "Routine <name>".
    private static func wokenLabel(_ message: ChatMessage) -> String? {
        guard let woken = message.metadata[AutomationKey.woken], !woken.isEmpty else { return nil }
        return woken == AutomationKind.heartbeat.rawValue ? "Heartbeat" : woken.prefix(1).uppercased() + woken.dropFirst()
    }

    /// P42's exchange card: "Jarvis → Infra: <first line>" or "Infra replied: <first line>"; a routine's card stays.
    private static func exchange(_ message: ChatMessage, context: TechnicalContext) -> TechnicalFold? {
        guard let origin = BotWorkOrigin(raw: message.metadata[BotWorkKey.origin]), let profile = origin.profile else { return nil }
        let request = message.metadata[BotWorkKey.request] ?? "", reply = message.metadata[BotWorkKey.reply] ?? ""
        let to = message.metadata[BotMessageKey.to].map(context.displayName) ?? context.botName
        let original = [request, reply].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return botLine(origin, profile: profile, to: to, body: request, original: original.isEmpty ? message.content : original, context: context)
    }

    private static func botLine(_ origin: BotWorkOrigin, profile: String, to: String, body: String, original: String, context: TechnicalContext) -> TechnicalFold {
        let name = context.displayName(profile), line = firstLine(body)
        if case .reply = origin { return TechnicalFold(kind: .botReply, summary: "\(name) replied: \(line)", original: original, profile: profile) }
        return TechnicalFold(kind: .botMessage, summary: "\(name) → \(to): \(line)", original: original, profile: profile)
    }

    /// `SB_CONTEXT_RECEIVED` → "Context received"; nil for anything but one upper-case word with underscores.
    private static func ack(_ text: String) -> String? {
        guard text.count <= 64, ackWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return nil }
        var word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.hasPrefix("SB_") { word.removeFirst(3) }
        let spaced = word.replacingOccurrences(of: "_", with: " ").lowercased()
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func match(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

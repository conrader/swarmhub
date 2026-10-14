import Foundation

/// P22 token rule: the manager text rides only on bot-management turns. A turn is one when the user's text asks for
/// bot management (EN + PL) or an exchange is still open (follow-ups such as "yes"). An exchange closes when a swarmhub
/// block arrives, after `maxFollowUps` follow-up turns, or `window` after it opened.
struct ManagementExchange: Equatable {
    var openedAt: Date
    var followUps = 0
    /// Opened from the Manage bots menu or the bot editor: the next turn is the opening turn, not a follow-up.
    var awaitingOpening = false

    static let maxFollowUps = 3
    static let window: TimeInterval = 10 * 60

    func isOpen(at now: Date) -> Bool { now.timeIntervalSince(openedAt) < Self.window && followUps < Self.maxFollowUps }

    /// Whether this turn carries the manager text, and the exchange that remains after it.
    static func decide(text: String, exchange: ManagementExchange?, now: Date) -> (attach: Bool, next: ManagementExchange?) {
        if var exchange, exchange.awaitingOpening, now.timeIntervalSince(exchange.openedAt) < window {
            exchange.awaitingOpening = false; exchange.openedAt = now
            return (true, exchange)
        }
        if ManagementIntent.matches(text) { return (true, ManagementExchange(openedAt: now)) }
        guard var exchange, !exchange.awaitingOpening, exchange.isOpen(at: now) else { return (false, nil) }
        exchange.followUps += 1
        return (true, exchange)
    }
}

enum ManagementIntent {
    private static let createVerbs = ["create", "new", "make", "add", "build", "set up", "setup", "spin up",
                                      "stwórz", "stworz", "utwórz", "utworz", "nowy", "nowego", "nową", "dodaj", "zrób", "zrob"]
    private static let botNouns = ["bot", "bots", "agent", "agents", "assistant", "assistants", "subagent", "subagents",
                                   "bota", "boty", "botów", "botow", "agenta", "agentów", "asystenta"]
    private static let retireVerbs = ["retire", "remove", "delete", "usuń", "usun", "wyłącz", "wylacz"]
    private static let retireNouns = ["bot", "bots", "agent", "bota", "agenta", "botów"]
    private static let phrases = ["instructions", "instruction", "soul.md", "soul", "system prompt", "avatar", "avatars",
                                  "list bots", "list the bots", "list all bots", "list my bots", "which bots", "what bots", "show bots",
                                  "instrukcje", "instrukcji", "instrukcja", "awatar", "awatara", "lista botów", "lista botow", "listę botów"]

    /// True when the text asks to create, retire or list bots, or to read or change a bot's instructions or avatar.
    static func matches(_ text: String) -> Bool {
        let words = tokens(text); guard !words.isEmpty else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        func has(_ phrase: String) -> Bool { joined.contains(" \(phrase) ") }
        if phrases.contains(where: has) { return true }
        if has("prompt"), botNouns.contains(where: has) { return true }
        if createVerbs.contains(where: has), botNouns.contains(where: has) { return true }
        return retireVerbs.contains(where: has) && retireNouns.contains(where: has)
    }

    /// Lowercased words; letters, digits, `.`, `-` and `'` stay inside a word, everything else separates.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'")) }.filter { !$0.isEmpty }
    }
}

/// The Manage bots menu: each item fills the composer with a plain request and opens an exchange.
enum ManageBotsAction: String, CaseIterable, Identifiable {
    case newBot, changeInstructions, changeAvatar, showInstructions, listBots, retireBot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newBot: "New bot…"
        case .changeInstructions: "Change instructions…"
        case .changeAvatar: "Change avatar…"
        case .showInstructions: "Show instructions…"
        case .listBots: "List bots"
        case .retireBot: "Retire bot…"
        }
    }

    var systemImage: String {
        switch self {
        case .newBot: "plus.circle"
        case .changeInstructions: "text.badge.checkmark"
        case .changeAvatar: "paintpalette"
        case .showInstructions: "doc.text"
        case .listBots: "list.bullet"
        case .retireBot: "archivebox"
        }
    }

    /// The request placed in the composer; `bot` names the profile when the user started from a bot.
    func request(bot: String? = nil) -> String {
        let target = bot ?? "<name>"
        switch self {
        case .newBot: return "Create a new bot called <name> that "
        case .changeInstructions: return "Change the instructions of the bot \(target): "
        case .changeAvatar: return "Change the avatar of the bot \(target) to "
        case .showInstructions: return "Show me the instructions of the bot \(target)."
        case .listBots: return "List the bots on this box."
        case .retireBot: return "Retire the bot \(target)."
        }
    }
}

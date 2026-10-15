import Foundation

/// P22 token rule: the manager text rides only on bot-management turns. A turn is one when the user's text asks for
/// bot management (EN + PL) or an exchange is still open (follow-ups such as "yes"). An exchange closes when a swarmhub
/// block arrives, after `maxFollowUps` follow-up turns, or `window` after it opened.
struct ManagementExchange: Equatable {
    var openedAt: Date
    var followUps = 0
    /// Opened from the Manage bots menu or the bot editor: the next turn is the opening turn, not a follow-up.
    var awaitingOpening = false
    /// P31 D+E: a SwarmHub request that carries its own recipe (the opening turn and the follow-ups, e.g. Konrad's yes).
    var recipe: String? = nil

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

    // P27: "switch all agents to 6.1 sol" — a change verb, bots (or all of them) and a model.
    private static let modelVerbs = ["switch", "change", "set", "move", "use", "upgrade",
                                     "przełącz", "przelacz", "zmień", "zmien", "ustaw"]
    private static let allWords = ["all", "every", "wszystkie", "wszystkich"]
    private static let modelWords = ["model", "models", "modelu", "modele"]

    /// True when the text asks to create, retire or list bots, to read or change a bot's instructions or avatar, or to
    /// change bots' model.
    static func matches(_ text: String) -> Bool {
        let words = tokens(text); guard !words.isEmpty else { return false }
        let joined = " " + words.joined(separator: " ") + " "
        func has(_ phrase: String) -> Bool { joined.contains(" \(phrase) ") }
        if phrases.contains(where: has) { return true }
        if has("prompt"), botNouns.contains(where: has) { return true }
        if createVerbs.contains(where: has), botNouns.contains(where: has) { return true }
        if modelVerbs.contains(where: has), (botNouns + allWords).contains(where: has),
           modelWords.contains(where: has) || words.contains(where: isModelLike) { return true }
        return retireVerbs.contains(where: has) && retireNouns.contains(where: has)
    }

    /// A model-ish token: a version like `6.1`, a word containing gpt/claude/opus/sonnet, or `sol`/`terra`. `sol` and `terra` count only as a whole part of a
    /// hyphenated token, so "resolution" or "terrace" are not models.
    static func isModelLike(_ word: String) -> Bool {
        if word.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil { return true }
        if ["gpt", "claude", "opus", "sonnet"].contains(where: word.contains) { return true }
        return word.split(separator: "-").contains { $0 == "sol" || $0 == "terra" }
    }

    /// Lowercased words; letters, digits, `.`, `-` and `'` stay inside a word, everything else separates.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'")) }.filter { !$0.isEmpty }
    }
}

/// The Manage bots menu: each item fills the composer with a plain request and opens an exchange.
enum ManageBotsAction: String, CaseIterable, Identifiable {
    case newBot, changeInstructions, changeAvatar, changeModel, changeSubAgentModel, showInstructions, listBots, retireBot
    var id: String { rawValue }

    /// The menu for a manager on this backend: "Change model…" and (P31 D) "Change coding model…" only where the
    /// manager text has a model recipe (Hermes; the OpenClaw text has none, P27 D8).
    static func actions(for backend: BackendKind) -> [ManageBotsAction] {
        backend == .hermes ? allCases : allCases.filter { $0 != .changeModel && $0 != .changeSubAgentModel }
    }

    var title: String {
        switch self {
        case .newBot: "New bot…"
        case .changeInstructions: "Change instructions…"
        case .changeAvatar: "Change avatar…"
        case .changeModel: "Change model…"
        case .changeSubAgentModel: "Change coding model…"
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
        case .changeModel: "cpu"
        case .changeSubAgentModel: "cpu.fill"
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
        case .changeModel: return "Change the model of \(bot ?? "<bots>") to "
        // Opens the coding model sheet instead of filling the composer (`AppStore.startManagement`).
        case .changeSubAgentModel: return "Change the coding model of \(bot ?? "<bots>") to "
        case .showInstructions: return "Show me the instructions of the bot \(target)."
        case .listBots: return "List the bots on this box."
        case .retireBot: return "Retire the bot \(target)."
        }
    }
}

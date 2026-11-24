import Foundation

/// Whether a message asks for a new bot, or for another model (English and Polish). A Herdr bot's agent is reminded
/// how to ask the app for that in front of such a message (`HerdrBackend.send`).
enum ManagementIntent {
    private static let createVerbs = ["create", "new", "make", "add", "build", "set up", "setup", "spin up",
                                      "stwórz", "stworz", "utwórz", "utworz", "nowy", "nowego", "nową", "dodaj", "zrób", "zrob"]
    private static let botNouns = ["bot", "bots", "agent", "agents", "assistant", "assistants", "subagent", "subagents",
                                   "bota", "boty", "botów", "botow", "botom", "agenta", "agenty", "agentów", "agentow", "asystenta"]

    static func createsBot(_ text: String) -> Bool {
        let joined = " " + tokens(text).joined(separator: " ") + " "
        return createVerbs.contains { joined.contains(" \($0) ") } && botNouns.contains { joined.contains(" \($0) ") }
    }

    private static let changeVerbs = ["set", "switch", "change", "move", "put", "use", "run", "make",
                                      "ustaw", "zmień", "zmien", "przełącz", "przelacz", "przestaw", "użyj", "uzyj", "daj", "zamień", "zamien"]
    private static let modelNouns = ["model", "models", "modelu", "modele", "modeli", "engine", "engines",
                                     "silnik", "silnika", "silniki", "silników", "silnikow", "runtime"]
    private static let programsAndModels = ["codex", "claude", "gemini", "opencode", "gpt", "astra", "sol", "neon",
                                            "terra", "sonnet", "opus", "haiku", "fable"]

    private static let towards = ["to", "on", "onto", "na", "do"]
    private static let everyone = ["all", "every", "everyone", "everybody", "wszystkie", "wszystkich", "wszystkim",
                                   "wszyscy", "każdy", "kazdy", "każdego", "kazdego"]

    /// The message may ask for another model or agent program ("set all bots to sol 6.2", "ustaw boty na sonnet").
    static func changesModel(_ text: String) -> Bool {
        let words = tokens(text)
        func names(_ word: String) -> Bool { programsAndModels.contains { word == $0 || word.hasPrefix($0 + "-") } }
        let namesModel = words.contains(where: names), hasModelNoun = words.contains(where: modelNouns.contains)
        guard namesModel || hasModelNoun else { return false }
        let namesBots = words.contains { botNouns.contains($0) || everyone.contains($0) }
        let namesDestination = zip(words, words.dropFirst()).contains { towards.contains($0.0) && names($0.1) }
        if words.contains(where: changeVerbs.contains) {
            return namesBots || namesDestination || (words.count <= 5 && (hasModelNoun || words.dropFirst().first.map(names) == true))
        }
        // Short follow-ups such as "Astra 6.2" or "wszystkie boty na Neon".
        return namesDestination && namesBots || words.first.map(names) == true
            && words.dropFirst().allSatisfy { $0.first?.isNumber == true || $0 == "mini" }
    }

    /// Lowercased words; letters, digits, `.`, `-` and `'` stay inside a word, everything else separates.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'")) }.filter { !$0.isEmpty }
    }
}

/// The main bot's "+" menu in its composer. "New bot…" fills the composer with a plain request; "Get to know me"
/// has the bot ask its few questions about the person (again), which the app sends at once.
enum ManageBotsAction: String, CaseIterable, Identifiable {
    case newBot, getToKnowMe
    var id: String { rawValue }
    var title: String { self == .newBot ? "New bot…" : HerdrIntro.menu }
    var systemImage: String { self == .newBot ? "plus.circle" : "hand.wave" }
    /// The request placed in the composer; nil for an action the app carries out itself.
    var request: String? { self == .newBot ? "Create a new bot called <name> that " : nil }
}

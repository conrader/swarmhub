import Foundation

/// P31 D1: which coding agent a bot's `code-job` tries, in order. The next one is used only when the previous is not
/// installed, not logged in, or hits a usage limit. Stored as the `--order` argument itself.
enum CodingOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCodexHermes = "claude,codex,hermes"
    case codexClaudeHermes = "codex,claude,hermes"
    case claudeOnly = "claude"
    case codexOnly = "codex"
    case hermesOnly = "hermes"

    static let standard = CodingOrder.claudeCodexHermes
    var id: String { rawValue }
    /// What `code-job --order` gets, and the variant recorded with the installed `swarmhub-coding` skill.
    var argument: String { rawValue }

    var title: String {
        switch self {
        case .claudeCodexHermes: "Claude Code → Codex → Hermes sub-agent"
        case .codexClaudeHermes: "Codex → Claude Code → Hermes sub-agent"
        case .claudeOnly: "Claude Code only"
        case .codexOnly: "Codex only"
        case .hermesOnly: "Hermes sub-agent only"
        }
    }

    static let help = "Who does a bot’s coding tasks. The next one is used only when the previous isn’t installed, isn’t logged in, or hits its usage limit. A change asks to update that bot’s coding skill."

    /// The bot's own choice, else the SwarmHub-wide default, else `fallback`: the bundle's `policy.codingOrder` (P6b),
    /// compiled Claude Code → Codex → Hermes sub-agent.
    static func resolve(bot: CodingOrder?, appDefault: CodingOrder?, fallback: CodingOrder = .standard) -> (order: CodingOrder, source: ModelSource) {
        if let bot { return (bot, .bot) }
        return (appDefault ?? fallback, .appDefault)
    }

    /// Decodes a stored value; an unknown one (a later build's order) reads as unset.
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> CodingOrder? {
        ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(CodingOrder.init(rawValue:))
    }
}

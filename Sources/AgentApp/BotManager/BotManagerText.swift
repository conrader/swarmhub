import CryptoKit
import Foundation

/// P22: the short bot-management text SwarmHub sends the manager bot on demand (`Resources/BotManager/manager-hermes.md`),
/// and the key both sides derive for a new bot. Nothing is installed on the box; the text travels with the turn.
/// P26: an OpenClaw manager gets `manager-openclaw.md` (no keys; `{{MANAGER}}` is its agent id).
enum BotManagerText {
    static let resourcePath = "BotManager/manager-hermes.md"
    static let openClawResourcePath = "BotManager/manager-openclaw.md"
    static var connectorHelper: String? { template(candidates: candidates("ConnectorDefaults/default-connectors.py")) }

    static func expandingConnectorHelper(_ text: String) -> String {
        text.replacingOccurrences(of: "{{CONNECTOR_HELPER}}", with: connectorHelper ?? "raise RuntimeError('Swarm Hub connector helper is missing')")
    }

    /// P31 C: the on-demand recipes split out of the core text (same placeholders). The `swarmhub-manager` skill ships
    /// them as `references/<name>.md`; SwarmHub's own quiet turns carry only the recipe they need.
    enum Recipe: String, CaseIterable {
        /// P35: list every bot, connect bots made before SwarmHub, restore a connected bot's old key.
        case box
        /// P31 C: the coding tools' accounts: status, install, login, check, code, logout.
        case accounts
        /// P31 D: each bot's model and sub-agent model, read from config.yaml (op `models`).
        case models
        /// P31 E: the box's capacity probe (op `box_capacity`) and the coding job limit.
        case capacity
        var resourcePath: String { "BotManager/recipes/\(rawValue).md" }
        var referencePath: String { "references/\(rawValue).md" }
    }

    /// The template file for a manager on this backend.
    static func resourcePath(for backend: BackendKind) -> String { backend == .openClaw ? openClawResourcePath : resourcePath }

    /// The installed app's Resources, the SwiftPM bundle next to the binary, or the checkout (tests); nil when absent.
    static func template(candidates: [URL] = defaultCandidates) -> String? {
        candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first { !$0.isEmpty }
    }

    static func template(for backend: BackendKind) -> String? { template(candidates: candidates(resourcePath(for: backend))) }

    static var defaultCandidates: [URL] { candidates(resourcePath) }

    static func recipe(_ recipe: Recipe) -> String? { template(candidates: candidates(recipe.resourcePath)) }

    /// The full text for a Hermes manager without the skill: the core and every recipe; nil when one is missing.
    static func fullTemplate(core: String? = template(), recipes: [String?] = Recipe.allCases.map(recipe)) -> String? {
        let parts = recipes.compactMap { $0 }
        guard let core, parts.count == recipes.count else { return nil }
        return ([core] + parts).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n") + "\n"
    }

    /// The recipes as the skill's extra files (placeholders kept; filled per profile at install); nil when one is missing.
    static func referenceFiles() -> [SkillFile]? {
        let files = Recipe.allCases.compactMap { recipe in self.recipe(recipe).map { SkillFile(path: recipe.referencePath, content: $0) } }
        return files.count == Recipe.allCases.count ? files : nil
    }

    static func candidates(_ resourcePath: String) -> [URL] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return [
            Bundle.main.resourceURL?.appending(path: resourcePath),
            executable.appending(path: "AgentApp_AgentApp.bundle/\(resourcePath)"),
            // P27: the SwiftPM bundle as newer toolchains lay it out (`Contents/Resources`).
            executable.appending(path: "AgentApp_AgentApp.bundle/Contents/Resources/\(resourcePath)"),
            executable.appending(path: "AgentApp.resources/\(resourcePath)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Resources/\(resourcePath)")
        ].compactMap { $0 }
    }

    /// `~/.hermes/.env` for the default profile, else `~/.hermes/profiles/<profile>/.env`.
    static func envPath(forProfile profile: String) -> String {
        profile == "default" ? "~/.hermes/.env" : "~/.hermes/profiles/\(profile)/.env"
    }

    /// The template with `{{MANAGER}}` and `{{MANAGER_ENV}}` filled for the manager's profile.
    static func filled(_ template: String, managerProfile profile: String) -> String {
        expandingConnectorHelper(template).replacingOccurrences(of: "{{MANAGER_ENV}}", with: envPath(forProfile: profile))
            .replacingOccurrences(of: "{{MANAGER}}", with: profile)
    }

    /// The OpenClaw template with `{{MANAGER}}` filled with the manager's agent id.
    static func filled(_ template: String, managerAgent agentID: String) -> String {
        expandingConnectorHelper(template).replacingOccurrences(of: "{{MANAGER}}", with: agentID)
    }

    /// A new bot's key: lowercase hex HMAC-SHA256(key = the manager's API key, message = `swarmhub-bot-key:v1:<name>`),
    /// the value the box computes with `openssl dgst -sha256 -hmac`. Never sent, logged or stored outside the Keychain.
    static func derivedKey(managerKey: String, botName: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("swarmhub-bot-key:v1:\(botName)".utf8), using: SymmetricKey(data: Data(managerKey.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

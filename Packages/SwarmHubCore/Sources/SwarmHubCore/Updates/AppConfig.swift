import Foundation

/// P6b (CORE-PLAN §1.2, §4, §8 step 6): every app setting a bundle may change, resolved once for the Mac and iOS
/// apps from the shared `ConfigStore`. A value is the bundle's when present, of the right type and inside its limits;
/// otherwise it is the compiled default here, which is what the apps did before bundles existed. Wrong types, values
/// out of limits and kill flags are logged by `ConfigStore` and read as the compiled default.
///
/// No key here can carry approval keys, approver lists, gates, or approval and secret endpoints: `ConfigDecoder`
/// refuses such names before any value is readable (§4), and approval rules are deliberately not a key at all.
/// Team actions can only be narrowed to the compiled set, never widened. `scripts/release/app_config_reference.py`
/// is the Python statement of this resolution; `config/app-config.json` holds the shared vectors.
public struct AppConfig: Equatable, Sendable {
    /// A (provider slug, model id) pair from `policy.modelDefaults`.
    public struct ModelPair: Equatable, Sendable {
        public var provider: String
        public var model: String
        public init(provider: String, model: String) { self.provider = provider; self.model = model }
    }

    public enum ModelRole: Sendable { case conversation, coding }

    /// An install's explicit opt-out is different from a role it has never configured.
    public enum ModelPreference: Equatable, Sendable {
        case unset, agentDefault, choice(ModelPair)
    }

    /// Shared Mac/iOS precedence: an explicit local choice (including agent default), then the bundle.
    /// A nil coding default retains the app's existing "same as conversation" behaviour.
    public func modelDefault(for role: ModelRole, preference: ModelPreference = .unset) -> ModelPair? {
        switch preference {
        case .agentDefault: return nil
        case .choice(let pair): return pair
        case .unset:
            switch role {
            case .conversation: return conversationModel
            case .coding: return codingModel
            }
        }
    }

    /// New teams' limits (`policy.teamLimits`); each member stays inside the range `TeamLimits.isValid` accepts.
    public struct TeamLimits: Equatable, Sendable {
        public var tasks = 12
        public var reviewRounds = 2
        public var handoffDepth = 3
        public var operations = 48
        public var parallelTasks = 1
        public var activeSeconds = 1800
        public init() {}
    }

    /// Defaults of the bot system prompt and orientation context, identical on Mac and iOS. The owner's own
    /// settings (name, coordinator choice, quiet hours) still win where the app has them.
    public struct BotPrompt: Equatable, Sendable {
        public var owner = "the user"
        public var role = "Personal assistant"
        public var language = "Match the user's current language; follow an explicit language preference."
        /// `automatic` (the Mac's coordinator rule) or `none` (report to the owner only).
        public var coordinator = "automatic"
        /// Minutes after midnight in the owner's time zone; an end before the start runs over midnight.
        public var quietHoursStart = 22 * 60
        public var quietHoursEnd = 8 * 60
        public init() {}
    }

    public var codingOrder = "claude,codex,hermes"
    public var conversationModel: ModelPair?
    public var codingModel: ModelPair?
    /// Sorted by byte order; always a non-empty subset of the compiled actions.
    public var teamActions = ["assign", "reportResult", "requestHelp", "requestReview"]
    public var teamLimits = TeamLimits()
    /// nil: the manager text compiled into the app (`Resources/BotManager/manager-hermes.md`).
    public var managerTemplate: String?
    /// nil: `Resources/BotManager/manager-openclaw.md`.
    public var managerTemplateOpenClaw: String?
    /// Recipe name (`accounts`, `box`, `capacity`, `models`) → text; a missing name is the compiled recipe file.
    public var managerRecipes: [String: String] = [:]
    public var botPrompt = BotPrompt()
    /// Mac: Settings → Models and the bot editor, under the coding agent picker.
    public var codingOrderHelp = "Who does a bot’s coding tasks. The next one is used only when the previous isn’t installed, isn’t logged in, or hits its usage limit. A change asks to update that bot’s coding skill."
    /// iOS: the setup screen's title.
    public var setupTitle = "Bring your agents."
    /// iOS: the footer under an agent's capability list.
    public var capabilityFooter = "Server capability support does not imply every mobile control is implemented in this foundation build."

    public init() {}

    /// Every compiled default: what both apps use with no bundle, an unreachable host or a kill switch.
    public static let compiled = AppConfig()

    /// Every key from `config`, in a fixed order (the order reports are logged in).
    public init(_ config: ConfigStore) {
        let keys = AppConfigKeys.self
        codingOrder = config.value(keys.codingOrder)
        let models = config.value(keys.modelDefaults)
        conversationModel = models["conversationProvider"].flatMap { provider in
            models["conversationModel"].map { ModelPair(provider: provider, model: $0) }
        }
        codingModel = models["codingProvider"].flatMap { provider in
            models["codingModel"].map { ModelPair(provider: provider, model: $0) }
        }
        teamActions = config.value(keys.teamActions)
        let limits = config.value(keys.teamLimits)
        teamLimits.tasks = Int(limits["tasks"] ?? Int64(teamLimits.tasks))
        teamLimits.reviewRounds = Int(limits["reviewRounds"] ?? Int64(teamLimits.reviewRounds))
        teamLimits.handoffDepth = Int(limits["handoffDepth"] ?? Int64(teamLimits.handoffDepth))
        teamLimits.operations = Int(limits["operations"] ?? Int64(teamLimits.operations))
        teamLimits.parallelTasks = Int(limits["parallelTasks"] ?? Int64(teamLimits.parallelTasks))
        teamLimits.activeSeconds = Int(limits["activeSeconds"] ?? Int64(teamLimits.activeSeconds))
        botPrompt.coordinator = config.value(keys.coordinator)
        botPrompt.quietHoursStart = Int(config.value(keys.quietHoursStart))
        botPrompt.quietHoursEnd = Int(config.value(keys.quietHoursEnd))
        managerTemplate = config.value(keys.managerTemplate)
        managerTemplateOpenClaw = config.value(keys.managerTemplateOpenClaw)
        for (name, key) in keys.managerRecipes { managerRecipes[name] = config.value(key) }
        botPrompt.owner = config.value(keys.owner)
        botPrompt.role = config.value(keys.role)
        botPrompt.language = config.value(keys.language)
        codingOrderHelp = config.value(keys.codingOrderHelp)
        setupTitle = config.value(keys.setupTitle)
        capabilityFooter = config.value(keys.capabilityFooter)
    }

    /// The one loader both apps call: the bundle the update client installed under `root` (Application Support by
    /// default), read once. Nothing installed, an unreadable store or no root: compiled defaults. Never fetches and
    /// never creates the store, so an unreachable update host changes nothing.
    public static func load(root: URL? = nil, log: @escaping ConfigStore.Log = ConfigStore.systemLog) -> AppConfig {
        guard let root = root ?? (try? UpdateStore.defaultRoot()),
              FileManager.default.fileExists(atPath: root.path) else { return .compiled }
        return AppConfig(ConfigStore(updates: UpdateStore(root: root), log: log))
    }
}

extension AppConfig {
    /// Every resolved value as `<domain>.<key>` → JSON, the shape of `config/app-config.json` snapshots. An unset
    /// optional text (the compiled resource) is absent.
    var snapshot: [String: JCS.Value] {
        var models: [String: JCS.Value] = [:]
        if let pair = conversationModel {
            models["conversationProvider"] = .string(pair.provider); models["conversationModel"] = .string(pair.model)
        }
        if let pair = codingModel { models["codingProvider"] = .string(pair.provider); models["codingModel"] = .string(pair.model) }
        let limits: [String: Int] = ["tasks": teamLimits.tasks, "reviewRounds": teamLimits.reviewRounds,
                                     "handoffDepth": teamLimits.handoffDepth, "operations": teamLimits.operations,
                                     "parallelTasks": teamLimits.parallelTasks, "activeSeconds": teamLimits.activeSeconds]
        // One member at a time keeps the type checker fast.
        var values: [String: JCS.Value] = [:]
        values["policy.codingOrder"] = .string(codingOrder)
        values["policy.modelDefaults"] = .object(models)
        values["policy.teamActions"] = .array(teamActions.map(JCS.Value.string))
        values["policy.teamLimits"] = .object(limits.mapValues { JCS.Value.integer(Int64($0)) })
        values["policy.botPrompt.coordinator"] = .string(botPrompt.coordinator)
        values["policy.botPrompt.quietHoursStart"] = .integer(Int64(botPrompt.quietHoursStart))
        values["policy.botPrompt.quietHoursEnd"] = .integer(Int64(botPrompt.quietHoursEnd))
        values["prompts.botPrompt.owner"] = .string(botPrompt.owner)
        values["prompts.botPrompt.role"] = .string(botPrompt.role)
        values["prompts.botPrompt.language"] = .string(botPrompt.language)
        values["copy.codingOrderHelp"] = .string(codingOrderHelp)
        values["copy.setupTitle"] = .string(setupTitle)
        values["copy.capabilityFooter"] = .string(capabilityFooter)
        if let managerTemplate { values["prompts.managerTemplate"] = .string(managerTemplate) }
        if let managerTemplateOpenClaw { values["prompts.managerTemplate.openclaw"] = .string(managerTemplateOpenClaw) }
        for (name, text) in managerRecipes { values["prompts.managerRecipe." + name] = .string(text) }
        return values
    }
}

/// The keys behind `AppConfig`, with their limits. Names must pass the §4 denylist (checked by tests); a bundle
/// value that breaks a limit reads as `out_of_range`.
enum AppConfigKeys {
    static let compiled = AppConfig.compiled
    static let codingOrders = ["claude,codex,hermes", "codex,claude,hermes", "claude", "codex", "hermes"]
    static let modelMembers = ["codingModel", "codingProvider", "conversationModel", "conversationProvider"]
    static let teamLimitRanges: [String: ClosedRange<Int64>] = [
        "activeSeconds": 60...86_400, "handoffDepth": 1...10, "operations": 4...400, "parallelTasks": 1...4,
        "reviewRounds": 1...5, "tasks": 2...100
    ]
    static let coordinators = ["automatic", "none"]
    static let recipes = ["accounts", "box", "capacity", "models"]

    static let codingOrder = oneOf(.policy, "codingOrder", compiled.codingOrder, codingOrders)
    static let modelDefaults = ConfigKey<[String: String]>(.policy, "modelDefaults", [:]) { value in
        guard case .object(let members) = value else { throw ConfigReadFailure(reason: "wrong_type") }
        var models: [String: String] = [:]
        for (name, member) in members {
            guard case .string(let text) = member else { throw ConfigReadFailure(reason: "wrong_type") }
            models[name] = text
        }
        let paired = ["coding", "conversation"].allSatisfy { (models[$0 + "Provider"] == nil) == (models[$0 + "Model"] == nil) }
        guard paired, models.allSatisfy({ modelMembers.contains($0.key) && usableID($0.value) }) else {
            throw ConfigReadFailure(reason: "out_of_range")
        }
        return models
    }
    static let teamActions = ConfigKey<[String]>(.policy, "teamActions", compiled.teamActions) { value in
        guard case .array(let items) = value else { throw ConfigReadFailure(reason: "wrong_type") }
        let names = try items.map(string)
        guard !names.isEmpty, Set(names).count == names.count, names.allSatisfy(compiled.teamActions.contains) else {
            throw ConfigReadFailure(reason: "out_of_range")
        }
        return ConfigDecoder.sortedNames(names)
    }
    static let teamLimits = ConfigKey<[String: Int64]>(.policy, "teamLimits", [:]) { value in
        guard case .object(let members) = value else { throw ConfigReadFailure(reason: "wrong_type") }
        var limits: [String: Int64] = [:]
        for (name, member) in members {
            guard case .integer(let number) = member else { throw ConfigReadFailure(reason: "wrong_type") }
            limits[name] = number
        }
        guard limits.allSatisfy({ teamLimitRanges[$0.key]?.contains($0.value) == true }) else {
            throw ConfigReadFailure(reason: "out_of_range")
        }
        return limits
    }
    static let coordinator = oneOf(.policy, "botPrompt.coordinator", compiled.botPrompt.coordinator, coordinators)
    static let quietHoursStart = ConfigKey<Int64>.policy("botPrompt.quietHoursStart",
                                                         default: Int64(compiled.botPrompt.quietHoursStart), range: 0...1439)
    static let quietHoursEnd = ConfigKey<Int64>.policy("botPrompt.quietHoursEnd",
                                                       default: Int64(compiled.botPrompt.quietHoursEnd), range: 0...1439)

    static let managerTemplate = optionalText(.prompts, "managerTemplate")
    static let managerTemplateOpenClaw = optionalText(.prompts, "managerTemplate.openclaw")
    static let managerRecipes = recipes.map { ($0, optionalText(.prompts, "managerRecipe." + $0)) }
    static let owner = text(.prompts, "botPrompt.owner", compiled.botPrompt.owner)
    static let role = text(.prompts, "botPrompt.role", compiled.botPrompt.role)
    static let language = text(.prompts, "botPrompt.language", compiled.botPrompt.language)

    static let codingOrderHelp = text(.copy, "codingOrderHelp", compiled.codingOrderHelp)
    static let setupTitle = text(.copy, "setupTitle", compiled.setupTitle)
    static let capabilityFooter = text(.copy, "capabilityFooter", compiled.capabilityFooter)

    /// Every key name, `<domain>.<key>`, in read order.
    static let names: [String] = {
        let policy = ["codingOrder", "modelDefaults", "teamActions", "teamLimits", "botPrompt.coordinator",
                      "botPrompt.quietHoursStart", "botPrompt.quietHoursEnd"].map { "policy." + $0 }
        let prompts = (["managerTemplate", "managerTemplate.openclaw"] + recipes.map { "managerRecipe." + $0 }
                       + ["botPrompt.owner", "botPrompt.role", "botPrompt.language"]).map { "prompts." + $0 }
        return policy + prompts + ["codingOrderHelp", "setupTitle", "capabilityFooter"].map { "copy." + $0 }
    }()

    private static func string(_ value: JCS.Value) throws -> String {
        guard case .string(let text) = value else { throw ConfigReadFailure(reason: "wrong_type") }
        return text
    }

    /// Printable ASCII without spaces, 1...200 bytes: a subset of what the Mac's `ModelChoice` accepts.
    static func usableID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...200).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func oneOf(_ domain: ConfigDomain, _ name: String, _ fallback: String, _ allowed: [String]) -> ConfigKey<String> {
        ConfigKey(domain, name, fallback) { value in
            let text = try string(value)
            guard allowed.contains(text) else { throw ConfigReadFailure(reason: "out_of_range") }
            return text
        }
    }

    /// A non-empty string; an empty one is `out_of_range`.
    private static func text(_ domain: ConfigDomain, _ name: String, _ fallback: String) -> ConfigKey<String> {
        ConfigKey(domain, name, fallback) { value in
            let text = try string(value)
            guard !text.isEmpty else { throw ConfigReadFailure(reason: "out_of_range") }
            return text
        }
    }

    private static func optionalText(_ domain: ConfigDomain, _ name: String) -> ConfigKey<String?> {
        ConfigKey(domain, name, nil) { value in
            let text = try string(value)
            guard !text.isEmpty else { throw ConfigReadFailure(reason: "out_of_range") }
            return text
        }
    }
}

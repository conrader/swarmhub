import Foundation

/// P13 model roles. Pure and `Sendable` (no SwiftUI, no network): the backend-neutral seam that says which model a
/// bot should use for each role. Only a provider slug and a model id are ever stored; never a name, URL or key.
enum ModelRole: String, Codable, Sendable, CaseIterable { case conversation, coding }

/// A (provider slug, model id) pair. Both pass `HermesModelCatalog.isUsableID` (≤200 characters, no control
/// characters); a decoded pair that does not is dropped.
struct ModelChoice: Codable, Sendable, Equatable, Hashable {
    let provider: String; let model: String

    init?(provider: String, model: String) {
        guard HermesModelCatalog.isUsableID(provider), HermesModelCatalog.isUsableID(model) else { return nil }
        self.provider = provider; self.model = model
    }

    enum CodingKeys: CodingKey { case provider, model }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let choice = ModelChoice(provider: try c.decode(String.self, forKey: .provider), model: try c.decode(String.self, forKey: .model)) else {
            throw DecodingError.dataCorruptedError(forKey: .model, in: c, debugDescription: "Not a usable provider/model id.")
        }
        self = choice
    }
}

/// One role's setting on a bot: follow the app-wide default, opt out of it (box default / same as conversation), or a pair.
enum ModelSetting: Codable, Sendable, Equatable {
    case inherit, box, choice(ModelChoice)

    enum CodingKeys: CodingKey { case kind, provider, model }
    /// An unknown kind, or a pinned kind without a usable pair, reads as `inherit`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? nil, model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        switch (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil {
        case "box": self = .box
        case "choice": self = provider.flatMap { p in model.flatMap { ModelChoice(provider: p, model: $0) } }.map { .choice($0) } ?? .inherit
        default: self = .inherit
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit: try c.encode("inherit", forKey: .kind)
        case .box: try c.encode("box", forKey: .kind)
        case .choice(let choice): try c.encode("choice", forKey: .kind); try c.encode(choice.provider, forKey: .provider); try c.encode(choice.model, forKey: .model)
        }
    }
}

struct BotModelSettings: Codable, Sendable, Equatable {
    var conversation: ModelSetting = .inherit
    var coding: ModelSetting = .inherit
    /// P31: this bot's own coding agent order; nil follows the SwarmHub-wide default.
    var codingAgent: CodingOrder?
    var isEmpty: Bool { conversation == .inherit && coding == .inherit && codingAgent == nil }

    enum CodingKeys: CodingKey { case conversation, coding, codingAgent }
    init(conversation: ModelSetting = .inherit, coding: ModelSetting = .inherit, codingAgent: CodingOrder? = nil) {
        self.conversation = conversation; self.coding = coding; self.codingAgent = codingAgent
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(ModelSetting.self, forKey: .conversation) ?? .inherit
        coding = try c.decodeIfPresent(ModelSetting.self, forKey: .coding) ?? .inherit
        codingAgent = CodingOrder.decode(c, .codingAgent)
    }
}

/// The app-wide defaults, local to this install. Empty (inert) until Konrad sets them.
struct ModelDefaults: Codable, Sendable, Equatable {
    var conversation: ModelChoice?
    var coding: ModelChoice?
    /// P31: the SwarmHub-wide coding agent order; nil = Claude Code → Codex → Hermes sub-agent.
    var codingAgent: CodingOrder?
    var isEmpty: Bool { conversation == nil && coding == nil && codingAgent == nil }

    enum CodingKeys: CodingKey { case conversation, coding, codingAgent }
    init(conversation: ModelChoice? = nil, coding: ModelChoice? = nil, codingAgent: CodingOrder? = nil) {
        self.conversation = conversation; self.coding = coding; self.codingAgent = codingAgent
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try? c.decodeIfPresent(ModelChoice.self, forKey: .conversation)
        coding = try? c.decodeIfPresent(ModelChoice.self, forKey: .coding)
        codingAgent = CodingOrder.decode(c, .codingAgent)
    }
}

/// Where a resolved value came from, in the words the UI shows.
enum ModelSource: Sendable, Equatable {
    case bot, appDefault, boxDefault, sameAsConversation

    var label: String {
        switch self {
        case .bot: "this bot"
        case .appDefault: "\(AppConstants.name) default"
        case .boxDefault: CurrentModel.agentDefault
        case .sameAsConversation: "same as conversation"
        }
    }
}

/// `choice == nil` means "whatever the box uses" (its default, or for Coding the conversation's resolution).
struct ResolvedModel: Sendable, Equatable { let choice: ModelChoice?; let source: ModelSource }

enum ModelPolicy {
    /// Per role, resolved when applied and never copied into the bot. Conversation: the bot's choice; else the box
    /// default if the bot opted out; else the app-wide default; else the box default. Coding: the bot's choice; else the
    /// conversation's value if the bot opted out; else the app-wide Coding default; else the conversation's value.
    static func resolve(role: ModelRole, settings: BotModelSettings?, defaults: ModelDefaults?) -> ResolvedModel {
        let settings = settings ?? .init(), defaults = defaults ?? .init()
        switch role {
        case .conversation:
            switch settings.conversation {
            case .choice(let choice): return .init(choice: choice, source: .bot)
            case .box: return .init(choice: nil, source: .boxDefault)
            case .inherit: return defaults.conversation.map { .init(choice: $0, source: .appDefault) } ?? .init(choice: nil, source: .boxDefault)
            }
        case .coding:
            let conversation = resolve(role: .conversation, settings: settings, defaults: defaults).choice
            switch settings.coding {
            case .choice(let choice): return .init(choice: choice, source: .bot)
            case .box: return .init(choice: conversation, source: .sameAsConversation)
            case .inherit: return defaults.coding.map { .init(choice: $0, source: .appDefault) } ?? .init(choice: conversation, source: .sameAsConversation)
            }
        }
    }
}

/// Fixed one-line reasons, each pinned by a test. P11's picker reasons stay beside these, reused verbatim.
enum ModelRoleReason: Sendable, Equatable {
    case noLock, noList, noRow, legacy, noFork, notOffered(String), permanent, boxOnly, subAgentsOff, openClaw

    var text: String {
        switch self {
        case .noLock: "This box can't switch a chat's model, so \(AppConstants.name) can't apply a model here."
        case .noList: "This box doesn't list its models, so \(AppConstants.name) can't check a choice before using it."
        case .noRow: "This box can't report a chat's model, so \(AppConstants.name) can't tell whether the chat is new."
        case .legacy: "This box only has the older chat API, which has no per-chat model."
        case .noFork: "Coding threads need conversation forks, which this box doesn't offer."
        case .notOffered(let model): "\(model) isn't offered by this agent."
        case .permanent: "Hermes can't unpin a chat, and a pinned chat has no fallback model."
        case .boxOnly: "Set on the box. Hermes doesn't let apps read or change it."
        case .subAgentsOff: "Sub-agents are turned off for this bot."
        case .openClaw: "Models come from the OpenClaw gateway once connected."
        }
    }

    /// Why the app could not apply a model to this bot's chats, from what its profile reported; nil when it can (or
    /// nothing is loaded yet). Same gates as the apply path: native sessions, the lock, a loaded list, the session row.
    static func blocker(_ info: BotServerInfo?) -> ModelRoleReason? {
        guard let info, info.fetchedAt != nil else { return nil }
        if info.sourceCatalog != nil { return nil }
        guard let capabilities = info.capabilities else { return info.lastLoadFailed ? nil : .legacy }
        if capabilities.features["session_chat_streaming"] != true { return .legacy }
        if !capabilities.sessionModelLock { return .noLock }
        if info.catalog.value == nil { return .noList }
        if capabilities.features["session_resources"] == false { return .noRow }
        return nil
    }
}

extension ModelPickerModel {
    /// P11's listed-only rule as a pure function: the supplier (by slug) lists the id and nothing disables it now.
    static func offers(_ options: HermesModelOptions, _ choice: ModelChoice) -> Bool { options.catalog(profile: "").offers(choice) }
}

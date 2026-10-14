import Foundation

/// P17: the models one agent's own backend offers, in a backend-neutral shape. Hermes reaches it through a mapper
/// (`HermesModelOptions.catalog(profile:)`); other backends plug in through `ModelCatalogProviding`. Pure and
/// deliberately not `Codable`: server strings are kept verbatim, tags and reasons are in our words.
struct ModelCatalog: Sendable, Equatable {
    /// How a chat's model is applied: Hermes locks permanently; OpenClaw pins reversibly once P12b exists.
    enum Pinning: Sendable, Equatable { case permanent, reversible, none }

    struct Supplier: Sendable, Equatable, Identifiable {
        var id: String { slug }
        let slug: String
        var aliases: [String] = []
        /// As sent, or the slug title-cased when the wire has no name.
        let name: String
        /// Our words (`preset`, `custom endpoint`, …); the default supplier's `default` tag is added by the picker.
        var tags: [String] = []
        var models: [String]
        /// Why one model cannot be chosen now (plan, rate limit), in our words.
        var reasons: [String: String] = [:]
        /// Why no model of this supplier can be chosen now (signed out); wins over `reasons`.
        var blockedReason: String?
        var needsSignIn = false

        func reason(for model: String) -> String? { blockedReason ?? reasons[model] }
        func answers(to provider: String) -> Bool {
            let wanted = provider.lowercased()
            return slug.lowercased() == wanted || aliases.contains { $0.lowercased() == wanted }
        }
        static func titleCased(_ slug: String) -> String {
            slug.split { $0 == "-" || $0 == "_" }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    struct AgentDefault: Sendable, Equatable { let model: String; var supplier: String? = nil }

    /// Listed suppliers, default first; setup skeletons are only counted (`hiddenCount`).
    var suppliers: [Supplier]
    var defaultSupplier: String?
    /// The agent's configured default (Hermes: the profile's top-level `model`). Not a promise of what answers.
    var agentDefault: AgentDefault?
    var hiddenCount = 0
    var pinning: Pinning
    /// Where the list comes from, as two strings: "your Hermes box" and "Profile grok-x".
    var place: String
    var detail: String

    /// The read-only reason for a catalog whose chats the app cannot apply a model to yet.
    static let switchingLater = "Choosing models for this agent's chats comes with OpenClaw support for switching."
    static let newAgent = "Models come from the agent's own backend once it exists."
    static let hermesOnceSaved = "Models come from the Hermes profile once the agent is saved."
    static let noBackend = "This agent has no model backend."
    static let archive = "This agent is a read-only archive."
    static let noKey = "Add this bot's key to see its models."

    var defaultSupplierRow: Supplier? { defaultSupplier.flatMap { slug in suppliers.first { $0.slug == slug } } }
    func supplier(answering provider: String) -> Supplier? { suppliers.first { $0.answers(to: provider) } }
    var hasChoices: Bool { suppliers.contains { supplier in supplier.models.contains { supplier.reason(for: $0) == nil } } }

    /// The supplier (by slug, as menu rows store it) lists the id and nothing disables it now; never the id alone.
    func offers(_ choice: ModelChoice) -> Bool {
        guard let supplier = suppliers.first(where: { $0.slug == choice.provider }), supplier.models.contains(choice.model) else { return false }
        return supplier.reason(for: choice.model) == nil
    }

    /// Model ids compare equal when one is the other with a vendor prefix (`vendor/model` vs `model`).
    static func sameModel(_ a: String, _ b: String) -> Bool { a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a) }
}

/// How a backend other than Hermes supplies its catalog (P12's `OpenClawBackend` conforms in its own file).
/// `secrets` are redacted from every error shown; `catalogScope` keys the cache entry like Hermes' `baseURL|profile`.
protocol ModelCatalogProviding: Sendable {
    var catalogScope: String { get }
    var secrets: [String] { get }
    func modelCatalog(sessionID: String?) async throws -> ModelCatalog
}

/// Whether a stored pair is offered by one agent's list, or the list was not there to check.
enum ModelCheck: Sendable, Equatable {
    case offered, notOffered, notChecked
    var word: String {
        switch self { case .offered: "offered"; case .notOffered: "not offered"; case .notChecked: "not checked" }
    }
}

/// A role's resolution plus whether this agent's own list offers it (nil when it resolves to the agent default).
struct EffectiveModel: Sendable, Equatable {
    let resolved: ResolvedModel
    let check: ModelCheck?
    /// What the chat runs on: a default the list lacks is skipped (P13 D3), so it runs on the agent default.
    var choice: ModelChoice? { check == .notOffered && resolved.source == .appDefault ? nil : resolved.choice }
    var source: ModelSource { check == .notOffered && resolved.source == .appDefault ? .boxDefault : resolved.source }
    /// "X isn't offered by this agent." and what follows, or nil.
    var note: String? {
        guard check == .notOffered, let choice = resolved.choice, resolved.source == .bot || resolved.source == .appDefault else { return nil }
        let follows = resolved.source == .appDefault ? "Chats here run on the agent default." : "A new chat stops until you change it."
        return ModelRoleReason.notOffered(choice.model).text + " " + follows
    }
}

extension ModelPolicy {
    static func check(_ choice: ModelChoice?, catalog: ModelCatalog?) -> ModelCheck? {
        guard let choice else { return nil }
        guard let catalog else { return .notChecked }
        return catalog.offers(choice) ? .offered : .notOffered
    }

    /// `resolve` plus the one validity check every surface uses (role lines, mismatch, Switch this chat, the editor,
    /// Settings and `prepareModel`).
    static func effective(role: ModelRole, settings: BotModelSettings?, defaults: ModelDefaults?, catalog: ModelCatalog?) -> EffectiveModel {
        let resolved = resolve(role: role, settings: settings, defaults: defaults)
        return .init(resolved: resolved, check: check(resolved.choice, catalog: catalog))
    }
}

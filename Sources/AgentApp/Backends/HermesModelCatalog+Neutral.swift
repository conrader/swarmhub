import Foundation

/// P17: one profile's `/api/model/options` as the neutral `ModelCatalog`. P11's tags and reasons live here now,
/// unchanged; the picker and every other surface read the catalog, never `HermesModelOptions`.
extension HermesModelOptions {
    func catalog(profile: String) -> ModelCatalog {
        let defaultRow = defaultProvider
        let listed = providers.filter { !$0.isSkeleton }
        let ordered = listed.filter { $0.slug == defaultRow?.slug } + listed.filter { $0.slug != defaultRow?.slug }
        let suppliers = ordered.map { row in
            var supplier = ModelCatalog.Supplier(slug: row.slug, aliases: row.aliases, name: row.name,
                                                 tags: Self.tag(for: row.source).map { [$0] } ?? [], models: row.models)
            if row.isSignedOut { supplier.blockedReason = "sign-in needed on the box"; supplier.needsSignIn = true }
            for model in row.models { if let reason = Self.reason(model, row) { supplier.reasons[model] = reason } }
            return supplier
        }
        return .init(suppliers: suppliers, defaultSupplier: defaultRow.flatMap { $0.isSkeleton ? nil : $0.slug },
                     agentDefault: model.map { .init(model: $0, supplier: defaultRow?.slug ?? provider) },
                     hiddenCount: providers.count - listed.count, pinning: .permanent, place: "your Hermes box", detail: "Profile \(profile)")
    }

    /// `source` in our words; `built-in`, `hermes` and `canonical` need no tag.
    static func tag(for source: String?) -> String? {
        switch source {
        case "virtual": "preset"
        case "local-runtime": "runs on the box"
        case "user-config", "model-config": "custom endpoint"
        case "configured-current": "sign-in needed"
        default: nil
        }
    }

    static func reason(_ model: String, _ supplier: HermesModelProvider) -> String? {
        if supplier.isSignedOut { return "sign-in needed on the box" }
        if supplier.unavailableModels.contains(model) { return supplier.freeTierPending ? "checking the plan" : "needs a paid plan" }
        switch supplier.limit {
        case .account(let resetsAt): return rateLimited(resetsAt)
        case .models(let models): if let entry = models[model] { return rateLimited(entry) }
        case nil: break
        }
        return nil
    }

    private static func rateLimited(_ until: Date?) -> String {
        until.map { "rate-limited until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "rate-limited"
    }
}

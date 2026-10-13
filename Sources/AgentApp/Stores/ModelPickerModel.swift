import Foundation

/// Everything the Overview "Model" section and the headless menu line show, decided from what the bot's Hermes
/// profile reported. Pure: no SwiftUI, no network. Server strings (names, ids) are used verbatim; the reasons are ours.
struct ModelPickerModel: Equatable, Sendable {
    /// More models than this under one supplier go into a submenu with the same title.
    static let submenuThreshold = 16
    static let buttonTitle = "Change model for this chat"
    static let buttonHelp = "Choosing a model pins this chat to it. Hermes has no way to unpin a chat afterwards."
    static let notListed = "not in the box's list"

    struct Item: Equatable, Sendable, Identifiable {
        var id: String { supplierSlug + "\n" + model }
        let model: String; let supplierSlug: String; let supplierName: String
        var isChecked = false
        var isServerDefault = false
        /// Why this one model cannot be chosen right now (supplier or plan state); nil when it can.
        var disabledReason: String?
        var isEnabled = false
        var accessibilityLabel: String { "\(model), \(supplierName)" }
        /// Small text after the id: the server default tag or the reason it is unavailable.
        var detail: String? { disabledReason ?? (isServerDefault ? "box default" : nil) }
    }

    struct Group: Equatable, Sendable, Identifiable {
        var id: String { slug }
        let slug: String; let name: String; let tags: [String]
        var items: [Item]
        /// Shown instead of items when the supplier lists nothing to pick.
        var note: String?
        var title: String { ([name] + tags).joined(separator: " · ") }
        var usesSubmenu: Bool { items.count > ModelPickerModel.submenuThreshold }
    }

    struct Note: Equatable, Sendable { let text: String; var isWarning = false; var offersRetry = false }

    var groups: [Group] = []
    /// Setup skeletons the box lists but has no credentials for.
    var hiddenCount = 0
    /// Without a menu, `notes` says why.
    var showsMenu = false
    var canSwitch = false
    var isSwitching = false
    /// Why the menu is read-only when it opens with every row disabled.
    var switchBlockedReason: String?
    var notes: [Note] = []
    var caption: String?
    var footer: String?
    /// The current-model line: id, supplier (or "not in the box's list") and where the value came from.
    var currentModel: String?
    var currentSupplier: String?
    var currentSource: String?
    var profile: String

    var currentCaption: String? { currentModel == nil ? nil : [currentSupplier, currentSource].compactMap { $0 }.joined(separator: " · ") }
    var currentAccessibilityLabel: String? { currentModel.map { [$0, currentSupplier].compactMap { $0 }.joined(separator: ", ") } }

    func item(provider: String, model: String) -> Item? { groups.first { $0.slug == provider }?.items.first { $0.model == model } }

    init(info: BotServerInfo?, current: CurrentModel?, sessionID: String?, profile: String) {
        self.profile = profile
        currentModel = current?.model; currentSource = current?.source
        isSwitching = info?.isSwitchingModel ?? false
        switch info?.modelOptions ?? .loading {
        case .loading: notes = [.init(text: "Loading the box's models…")]
        case .unavailable(let reason): notes = [.init(text: reason)]
        case .failed(let reason): notes = [.init(text: reason, offersRetry: true)]
        case .loaded(let options): build(options, info: info!, current: current, sessionID: sessionID)
        }
    }

    private mutating func build(_ options: HermesModelOptions, info: BotServerInfo, current: CurrentModel?, sessionID: String?) {
        showsMenu = true
        let defaultSupplier = options.defaultProvider
        let listed = options.providers.filter { !$0.isSkeleton }
        hiddenCount = options.providers.count - listed.count
        let ordered = listed.filter { $0.slug == defaultSupplier?.slug } + listed.filter { $0.slug != defaultSupplier?.slug }
        canSwitch = info.canLockSessionModel && sessionID != nil && !info.isSwitchingModel
        let checkedSlug = current.flatMap { Self.checkedSupplier(for: $0, in: ordered, default: defaultSupplier) }

        groups = ordered.map { supplier in
            let isDefault = supplier.slug == defaultSupplier?.slug
            var tags = isDefault ? ["default"] : []
            if let tag = Self.tag(for: supplier.source) { tags.append(tag) }
            let items: [Item] = supplier.models.map { model in
                var item = Item(model: model, supplierSlug: supplier.slug, supplierName: supplier.name)
                item.isServerDefault = isDefault && options.model == model
                item.disabledReason = Self.reason(model, supplier)
                item.isEnabled = canSwitch && item.disabledReason == nil
                return item
            }
            var group = Group(slug: supplier.slug, name: supplier.name, tags: tags, items: Self.ticked(items, current: current?.model, under: checkedSlug))
            if items.isEmpty { group.note = supplier.isSignedOut ? "Sign-in needed on the box" : "No models listed" }
            return group
        }

        if let current {
            if let checkedSlug { currentSupplier = groups.first { $0.slug == checkedSlug }?.name }
            else if !ordered.contains(where: { $0.models.contains { HermesModelOptions.sameModel($0, current.model) } }) { currentSupplier = Self.notListed }
        }

        if let defaultSupplier, defaultSupplier.isSignedOut {
            notes.append(.init(text: "\(defaultSupplier.name), the default supplier, needs a new sign-in on the box.", isWarning: true))
        }
        if !groups.contains(where: { $0.items.contains { $0.disabledReason == nil } }) {
            notes.append(.init(text: "No supplier on the box can serve a model right now. Provider keys live on the box; Torvli never holds them."))
        }
        if !info.canLockSessionModel { switchBlockedReason = "Read-only: this server cannot switch a chat's model." }
        else if sessionID == nil { switchBlockedReason = "Send a message first; the model is chosen per chat." }
        else if info.isSwitchingModel { switchBlockedReason = "A switch is in progress." }
        if let reason = switchBlockedReason, !info.isSwitchingModel { notes.append(.init(text: reason)) }

        if groups.count == 1 { caption = "Models provided by \(groups[0].name) on your Hermes box" }
        else if groups.count > 1 {
            caption = "Models provided by \(groups.count) providers on your Hermes box" + (defaultSupplier.map { " · default \($0.name)" } ?? "")
        }
        var footer = ["Profile \(profile)"]
        if let fetchedAt = info.fetchedAt { footer.append("updated \(fetchedAt.formatted(date: .omitted, time: .shortened))") }
        if hiddenCount > 0 { footer.append("\(hiddenCount) provider\(hiddenCount == 1 ? "" : "s") not configured on the box") }
        self.footer = footer.joined(separator: " · ")
    }

    /// The lock's (or default's) provider by slug or alias, else the default supplier if it lists the id, else the
    /// only supplier that lists it, else none.
    static func checkedSupplier(for current: CurrentModel, in suppliers: [HermesModelProvider], default defaultSupplier: HermesModelProvider?) -> String? {
        func lists(_ supplier: HermesModelProvider) -> Bool { supplier.models.contains { HermesModelOptions.sameModel($0, current.model) } }
        if let provider = current.provider, let named = suppliers.first(where: { $0.answers(to: provider) }) { return lists(named) ? named.slug : nil }
        if let defaultSupplier, suppliers.contains(where: { $0.slug == defaultSupplier.slug }), lists(defaultSupplier) { return defaultSupplier.slug }
        let listing = suppliers.filter(lists)
        return listing.count == 1 ? listing[0].slug : nil
    }

    private static func ticked(_ items: [Item], current: String?, under slug: String?) -> [Item] {
        guard let current, let slug, items.first?.supplierSlug == slug else { return items }
        let index = items.firstIndex { $0.model == current } ?? items.firstIndex { HermesModelOptions.sameModel($0.model, current) }
        var items = items
        if let index { items[index].isChecked = true }
        return items
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

    /// One line per bot for `--render-snapshot`: names and counts only.
    func headlessLine(botName: String) -> String {
        guard showsMenu else { return "\(botName): model menu none (\(notes.first?.text ?? "no reason"))" }
        let suppliers = groups.map { group in
            ([group.name] + group.tags.map { "[\($0)]" } + ["\(group.items.count)"] + (group.usesSubmenu ? ["submenu"] : [])).joined(separator: " ")
        }
        let switching = canSwitch ? "switching on" : "switching off (\(switchBlockedReason ?? "no reason"))"
        return "\(botName): model menu \(suppliers.isEmpty ? "empty" : suppliers.joined(separator: " | ")); hidden \(hiddenCount); profile \(profile); \(switching)"
    }
}

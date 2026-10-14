import Foundation

/// Everything the Overview "Model" section and the headless menu line show, decided from what the bot's Hermes
/// profile reported. Pure: no SwiftUI, no network. Server strings (names, ids) are used verbatim; the reasons are ours.
struct ModelPickerModel: Equatable, Sendable {
    /// More models than this under one supplier go into a submenu with the same title.
    static let submenuThreshold = 16
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
        var detail: String? { disabledReason ?? (isServerDefault ? CurrentModel.agentDefault : nil) }
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
    /// The same, as a case the right panel's plain line (P21b) maps to its own words.
    enum Block: Equatable, Sendable { case notYet, readOnly, noChat, switching }
    var blocked: Block?
    /// The list has not arrived yet.
    var isLoading = false
    var notes: [Note] = []
    var caption: String?
    var footer: String?
    /// The current-model line: id, supplier (or "not in the box's list") and where the value came from.
    var currentModel: String?
    var currentSupplier: String?
    var currentSource: String?
    /// "last reply: <model>" when an unpinned chat's last reply ran on another model than the default it now shows.
    var lastReplyCaption: String?
    var profile: String

    var currentCaption: String? { currentModel == nil ? nil : [currentSupplier, currentSource].compactMap { $0 }.joined(separator: " · ") }
    var currentAccessibilityLabel: String? { currentModel.map { [$0, currentSupplier].compactMap { $0 }.joined(separator: ", ") } }

    func item(provider: String, model: String) -> Item? { groups.first { $0.slug == provider }?.items.first { $0.model == model } }

    /// The catalog's pinning; the "cannot unpin" copy shows only for `.permanent`.
    var pinning: ModelCatalog.Pinning = .permanent
    var unpinHelp: String? { pinning == .permanent ? Self.buttonHelp : nil }

    init(info: BotServerInfo?, current: CurrentModel?, sessionID: String?, profile: String) {
        self.profile = profile
        currentModel = current?.model; currentSource = current?.source
        lastReplyCaption = current?.lastReplyModel.map { "last reply: \($0)" }
        isSwitching = info?.isSwitchingModel ?? false
        switch info?.catalog(profile: profile) ?? .loading {
        case .loading: notes = [.init(text: "Loading the box's models…")]; isLoading = true
        case .unavailable(let reason): notes = [.init(text: reason)]
        case .failed(let reason): notes = [.init(text: reason, offersRetry: true)]
        case .loaded(let catalog): build(catalog, info: info!, current: current, sessionID: sessionID)
        }
    }

    /// Without `info` (a bot that cannot be asked), the reason alone.
    init(reason: String, profile: String) { self.profile = profile; notes = [.init(text: reason)] }

    private mutating func build(_ catalog: ModelCatalog, info: BotServerInfo, current: CurrentModel?, sessionID: String?) {
        showsMenu = true
        pinning = catalog.pinning
        let defaultSupplier = catalog.defaultSupplierRow
        hiddenCount = catalog.hiddenCount
        let canPin = catalog.pinning == .permanent
        canSwitch = canPin && info.canLockSessionModel && sessionID != nil && !info.isSwitchingModel && info.refreshError == nil
        let checkedSlug = current.flatMap { Self.checkedSupplier(for: $0, in: catalog) }

        groups = catalog.suppliers.map { supplier in
            let isDefault = supplier.slug == defaultSupplier?.slug
            let items: [Item] = supplier.models.map { model in
                var item = Item(model: model, supplierSlug: supplier.slug, supplierName: supplier.name)
                item.isServerDefault = isDefault && catalog.agentDefault?.model == model
                item.disabledReason = supplier.reason(for: model)
                item.isEnabled = canSwitch && item.disabledReason == nil
                return item
            }
            var group = Group(slug: supplier.slug, name: supplier.name, tags: (isDefault ? ["default"] : []) + supplier.tags, items: Self.ticked(items, current: current?.model, under: checkedSlug))
            if items.isEmpty { group.note = supplier.needsSignIn ? "Sign-in needed on the box" : "No models listed" }
            return group
        }

        if let current {
            if let checkedSlug { currentSupplier = groups.first { $0.slug == checkedSlug }?.name }
            else if !catalog.suppliers.contains(where: { $0.models.contains { ModelCatalog.sameModel($0, current.model) } }) { currentSupplier = Self.notListed }
        }

        if let defaultSupplier, defaultSupplier.needsSignIn {
            notes.append(.init(text: "\(defaultSupplier.name), the default supplier, needs a new sign-in on the box.", isWarning: true))
        }
        if !catalog.hasChoices {
            notes.append(.init(text: "No supplier on the box can serve a model right now. Provider keys live on the box; \(AppConstants.name) never holds them."))
        }
        if !canPin { switchBlockedReason = ModelCatalog.switchingLater; blocked = .notYet }
        else if !info.canLockSessionModel { switchBlockedReason = "Read-only: this server cannot switch a chat's model."; blocked = .readOnly }
        else if sessionID == nil { switchBlockedReason = "Send a message first; the model is chosen per chat."; blocked = .noChat }
        else if info.isSwitchingModel { switchBlockedReason = "A switch is in progress."; blocked = .switching }
        if let reason = switchBlockedReason, !info.isSwitchingModel { notes.append(.init(text: reason)) }
        if let error = info.refreshError {
            let asOf = info.modelsAsOf.map { " Showing the list from \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            notes.append(.init(text: error + asOf, isWarning: true, offersRetry: true))
        }

        if groups.count == 1 { caption = "Models provided by \(groups[0].name) on \(catalog.place)" }
        else if groups.count > 1 {
            caption = "Models provided by \(groups.count) providers on \(catalog.place)" + (defaultSupplier.map { " · default \($0.name)" } ?? "")
        }
        var footer = [catalog.detail]
        if let fetchedAt = info.fetchedAt { footer.append("updated \(fetchedAt.formatted(date: .omitted, time: .shortened))") }
        if hiddenCount > 0 { footer.append("\(hiddenCount) provider\(hiddenCount == 1 ? "" : "s") not configured on the box") }
        self.footer = footer.joined(separator: " · ")
    }

    /// The lock's (or default's) provider by slug or alias, else the default supplier if it lists the id, else the
    /// only supplier that lists it, else none.
    static func checkedSupplier(for current: CurrentModel, in catalog: ModelCatalog) -> String? {
        func lists(_ supplier: ModelCatalog.Supplier) -> Bool { supplier.models.contains { ModelCatalog.sameModel($0, current.model) } }
        if let provider = current.provider, let named = catalog.supplier(answering: provider) { return lists(named) ? named.slug : nil }
        if let defaultSupplier = catalog.defaultSupplierRow, lists(defaultSupplier) { return defaultSupplier.slug }
        let listing = catalog.suppliers.filter(lists)
        return listing.count == 1 ? listing[0].slug : nil
    }

    private static func ticked(_ items: [Item], current: String?, under slug: String?) -> [Item] {
        guard let current, let slug, items.first?.supplierSlug == slug else { return items }
        let index = items.firstIndex { $0.model == current } ?? items.firstIndex { ModelCatalog.sameModel($0.model, current) }
        var items = items
        if let index { items[index].isChecked = true }
        return items
    }

    /// P11's tags, now owned by the Hermes mapper.
    static func tag(for source: String?) -> String? { HermesModelOptions.tag(for: source) }

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

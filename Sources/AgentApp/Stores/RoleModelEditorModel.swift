import Foundation

/// P17: what the agent editor's Models section shows, decided from that agent's own catalog and the pending Backend
/// picker. Pure: no SwiftUI, no network. Leading rows first ("<app> default (X)" only when set, then "Agent default (Y)"),
/// then the catalog's supplier groups; never a text field.
struct RoleModelEditorModel: Equatable {
    struct Leading: Equatable { let title: String; let setting: ModelSetting }

    var leading: [Leading] = []
    /// One line in every state: why there is no list, or where the list comes from.
    var reason: String
    var offersRetry = false
    /// The menu is shown (a loaded list) and enabled only when the app can apply its models (`.permanent`).
    var showsMenu = false
    var canChoose = false
    var label: String
    /// The stored pair or the app default is not in this agent's list.
    var warning: String?
    var showsUnpinCopy = false

    /// `catalog` is nil for a new agent or a pending backend that differs from the saved one (nothing is loaded).
    init(isNew: Bool, savedBackend: BackendKind?, pendingBackend: BackendKind, catalog: Loadable<ModelCatalog>, hasEntry: Bool,
         autoLoad: Bool, refreshNote: String? = nil, appDefault: ModelChoice?, setting: ModelSetting) {
        let loaded = catalog.value
        let agentDefault = "Agent default (\(loaded?.agentDefault?.model ?? "unknown"))"
        let appDefaultTitle = appDefault.map { "\(AppConstants.name) default (\($0.model))" }
        switch setting {
        case .inherit: label = appDefaultTitle ?? agentDefault
        case .box: label = agentDefault
        case .choice(let choice): label = choice.model
        }
        if isNew { reason = ModelCatalog.newAgent; return }
        if pendingBackend != savedBackend {
            switch pendingBackend {
            case .openClaw: reason = ModelRoleReason.openClaw.text
            case .hermes: reason = ModelCatalog.hermesOnceSaved
            case .mock: reason = ModelCatalog.noBackend
            }
            label = agentDefault
            return
        }
        switch catalog {
        case .loading: reason = !hasEntry && !autoLoad ? "Not loaded yet." : "Loading this agent's models…"
        case .unavailable(let text): reason = text
        case .failed(let text): reason = text; offersRetry = true
        case .loaded(let catalog):
            showsMenu = true
            canChoose = catalog.pinning == .permanent
            showsUnpinCopy = canChoose
            reason = canChoose ? "Models from \(catalog.detail) on \(catalog.place)." : ModelCatalog.switchingLater
            if let refreshNote { reason += " " + refreshNote; offersRetry = true }
            if let appDefault, let title = appDefaultTitle {
                leading.append(.init(title: catalog.offers(appDefault) ? title : title + " — not offered by this agent", setting: .inherit))
            }
            leading.append(.init(title: agentDefault, setting: .box))
            let effective = ModelPolicy.effective(role: .conversation, settings: .init(conversation: setting), defaults: .init(conversation: appDefault), catalog: catalog)
            warning = effective.note
        }
    }
}

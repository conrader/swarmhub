import Foundation

/// Settings → Models, the Overview's role lines and the headless roles line, decided from what each bot's Hermes
/// profile reported plus the local role settings. Pure: no SwiftUI, no network. Server strings render verbatim.
struct ModelRolesModel: Equatable, Sendable {
    static let caption = "\(AppConstants.name) remembers these choices and applies them when it starts a chat. It does not change your box's own settings."
    static let conversationHelp = "Used for chats, group chats and threads \(AppConstants.name) starts."
    static let codingHelp = "Used for coding threads. Sub-agents use whatever the box sets."

    /// What the store knows about one bot; `current` is the model its main chat runs (P11's `currentModel`).
    struct Input: Sendable {
        let id: UUID; let name: String; let server: String; let profile: String
        var isOpenClaw = false
        /// P17: this bot's own catalog, or why it has none (`AppStore.modelCatalog(for:)`); nil reads `info`.
        var catalog: Loadable<ModelCatalog>?
        /// False for bots that cannot be asked (OpenClaw stub, mock, archive, history only); their row is the reason.
        var canAsk = true
        var info: BotServerInfo?
        var settings: BotModelSettings?
        var defaults: ModelDefaults?
        var current: CurrentModel?
        var isLocked = false
    }

    struct RoleLine: Equatable, Sendable {
        let role: ModelRole; let model: String; let supplier: String?; let source: ModelSource
        /// "X isn't offered by this agent." and what follows, when the stored pair is not in this agent's list.
        var note: String? = nil
        var title: String { role == .conversation ? "Conversation" : "Coding threads" }
        /// "<model> · <supplier> · <source>"; a Coding line that follows the conversation says only that.
        var value: String { role == .coding && source == .sameAsConversation ? source.label : [model, supplier, source.label].compactMap { $0 }.joined(separator: " · ") }
        var text: String { "\(title): \(value)" }
        var accessibilityLabel: String { [title, model, supplier ?? "supplier unknown", source.label].joined(separator: ", ") }
    }

    struct Row: Equatable, Sendable, Identifiable {
        let id: UUID; let name: String; let server: String; let profile: String; let isOpenClaw: Bool
        var conversation: RoleLine?; var coding: RoleLine?
        /// The agent default its own backend reported; nil until loaded.
        var boxDefault: String?
        var canAsk = true
        var catalog: ModelCatalog?
        /// Why this row has no list (not loaded, unavailable, failed, or cannot be asked).
        var catalogReason: String?
        /// A list the app cannot apply models from yet (`pinning` other than `.permanent`).
        var readOnly: String?
        /// `delegation` toolset: true on, false off, nil unknown or not listed.
        var delegation: Bool?
        var delegationListed = false
        var blocked: ModelRoleReason?
        /// "This chat runs A; this bot's default is B." when the main chat runs something else than it resolves to.
        var mismatch: String?
        /// The mismatch can be fixed with one lock ("Switch this chat"); `switchNote` says when that pins the box default.
        var canSwitch = false
        var switchNote: String?
        var loadError: String?
        var subAgents: String {
            guard delegationListed else { return "not listed" }
            return delegation.map { $0 ? "on" : "off" } ?? "unknown"
        }
    }

    var rows: [Row]

    init(_ inputs: [Input]) { rows = inputs.map(Self.row) }

    static func row(_ input: Input) -> Row {
        var row = Row(id: input.id, name: input.name, server: input.server, profile: input.profile, isOpenClaw: input.isOpenClaw)
        let state = input.catalog ?? input.info?.catalog(profile: input.profile) ?? .loading
        let catalog = state.value
        row.canAsk = input.canAsk; row.catalog = catalog
        switch state {
        case .loaded(let catalog): if catalog.pinning != .permanent { row.readOnly = ModelCatalog.switchingLater }
        case .loading: row.catalogReason = "not loaded"
        case .unavailable(let reason), .failed(let reason): row.catalogReason = reason
        }
        guard input.canAsk else { return row }
        row.boxDefault = catalog?.agentDefault?.model
        if case .loaded(let toolsets) = input.info?.toolsets, let delegation = toolsets.first(where: { $0.name == "delegation" }) {
            row.delegationListed = true; row.delegation = delegation.enabled
        }
        if input.info?.lastLoadFailed == true, case .failed(let reason) = state { row.loadError = reason }
        else if let error = input.info?.refreshError { row.loadError = error }
        row.blocked = ModelRoleReason.blocker(input.info)
        let conversation = ModelPolicy.effective(role: .conversation, settings: input.settings, defaults: input.defaults, catalog: catalog)
        let coding = ModelPolicy.effective(role: .coding, settings: input.settings, defaults: input.defaults, catalog: catalog)
        row.conversation = line(.conversation, conversation, catalog: catalog, loaded: input.info?.fetchedAt != nil)
        row.coding = line(.coding, coding, catalog: catalog, loaded: input.info?.fetchedAt != nil)
        if let runs = input.current, runs.source != CurrentModel.agentDefault, let wanted = conversation.choice?.model ?? catalog?.agentDefault?.model,
           !ModelCatalog.sameModel(runs.model, wanted) {
            row.mismatch = "This chat runs \(runs.model); this bot's default is \(wanted)."
            row.canSwitch = row.blocked == nil && input.info?.isSwitchingModel != true && conversation.check != .notOffered && catalog?.pinning == .permanent
            if conversation.choice == nil, input.isLocked { row.switchNote = pinNote(wanted) }
        }
        return row
    }

    private static func line(_ role: ModelRole, _ effective: EffectiveModel, catalog: ModelCatalog?, loaded: Bool) -> RoleLine {
        if let choice = effective.choice {
            let supplier = catalog?.supplier(answering: choice.provider)?.name ?? choice.provider
            return .init(role: role, model: choice.model, supplier: supplier, source: effective.source, note: effective.note)
        }
        let model = catalog?.agentDefault?.model ?? (loaded ? "not reported" : "not loaded")
        return .init(role: role, model: model, supplier: catalog?.agentDefault == nil ? nil : catalog?.defaultSupplierRow?.name, source: effective.source, note: effective.note)
    }

    static func pinNote(_ model: String) -> String { "Hermes can't unpin a chat; this pins it to the agent's current default (\(model))." }

    /// Settings → Models under the Torvli-wide default: "Offered by N of M agents; not by A, B; K not loaded". M counts
    /// the agents that can be asked, K those of M with no loaded list.
    func offerSummary(_ choice: ModelChoice?) -> String? {
        guard let choice else { return nil }
        let asked = rows.filter(\.canAsk)
        let loaded = asked.filter { $0.catalog != nil }
        let missing = loaded.filter { $0.catalog?.offers(choice) != true }.map(\.name)
        var text = "Offered by \(loaded.count - missing.count) of \(asked.count) agents"
        if !missing.isEmpty { text += "; not by " + missing.joined(separator: ", ") }
        if asked.count > loaded.count { text += "; \(asked.count - loaded.count) not loaded" }
        return text
    }

    var hermesRows: [Row] { rows.filter { !$0.isOpenClaw } }
    /// Rows Load can read: Hermes bots and any agent whose backend supplies a catalog.
    var askableRows: [Row] { rows.filter(\.canAsk) }

    /// Rows grouped by server in first-seen order, as Settings → Usage groups profiles.
    var servers: [(server: String, rows: [Row])] {
        var order: [String] = [], groups: [String: [Row]] = [:]
        for row in rows {
            if groups[row.server] == nil { order.append(row.server) }
            groups[row.server, default: []].append(row)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// "box default: X on 16 of 16 bots" or "differs: X on 9, Y on 7" (plus how many are not loaded).
    var fleetSummary: String {
        let total = hermesRows.count
        guard total > 0 else { return "no Hermes bots" }
        var counts: [(model: String, count: Int)] = []
        for model in hermesRows.compactMap(\.boxDefault) {
            if let index = counts.firstIndex(where: { $0.model == model }) { counts[index].count += 1 } else { counts.append((model, 1)) }
        }
        let missing = total - counts.reduce(0) { $0 + $1.count }
        if counts.isEmpty { return "agent default: not loaded (press Load)" }
        if counts.count == 1 { return "agent default: \(counts[0].model) on \(counts[0].count) of \(total) bots" }
        let parts = counts.sorted { $0.count > $1.count }.map { "\($0.model) on \($0.count)" }
        return "differs: " + parts.joined(separator: ", ") + (missing > 0 ? ", not loaded on \(missing)" : "")
    }

    /// "Sub-agents on for N of M bots" from the `delegation` toolset, or why it is unknown.
    var subAgentSummary: String {
        let listed = hermesRows.filter(\.delegationListed)
        guard !listed.isEmpty else { return "delegation toolset not loaded" }
        return "delegation toolset on for \(listed.filter { $0.delegation == true }.count) of \(hermesRows.count) bots"
    }

    /// Part C: "Last turn ran on <model> · <supplier>" from the session's last `runtime{}`, and, when it differs from
    /// the lock the app recorded for that session, "Ran on A, not the B you chose."
    struct RanOn: Equatable, Sendable { let line: String; let mismatch: String? }

    static func ranOn(_ runtime: HermesRuntime?, lock: HermesModelLock?, sessionID: String?, options: HermesModelOptions?) -> RanOn? {
        ranOn(runtime, lock: lock, sessionID: sessionID, catalog: options?.catalog(profile: ""))
    }
    static func ranOn(_ runtime: HermesRuntime?, lock: HermesModelLock?, sessionID: String?, catalog: ModelCatalog?) -> RanOn? {
        guard let runtime, let sessionID else { return nil }
        let supplier = runtime.provider.map { slug in catalog?.supplier(answering: slug)?.name ?? slug }
        let line = "Last turn ran on " + [runtime.model, supplier].compactMap { $0 }.joined(separator: " · ")
        guard let lock, lock.sessionID == sessionID, !ModelCatalog.sameModel(runtime.model, lock.model) else { return .init(line: line, mismatch: nil) }
        return .init(line: line, mismatch: "Ran on \(runtime.model), not the \(lock.model) you chose.")
    }

    /// The confirmation for "Use the box default instead": a lock to the agent's current default pair, which pins.
    static func boxDefaultNote(_ options: HermesModelOptions?) -> String? { boxDefaultNote(catalog: options?.catalog(profile: "")) }
    static func boxDefaultNote(catalog: ModelCatalog?) -> String? {
        guard let model = catalog?.agentDefault?.model, catalog?.defaultSupplierRow != nil, catalog?.pinning == .permanent else { return nil }
        return pinNote(model)
    }

    /// One line per bot for `--render-snapshot`: names and counts only.
    static func headlessLine(_ row: Row) -> String {
        guard row.canAsk else { return "\(row.name): roles \(row.catalogReason ?? ModelRoleReason.openClaw.text)" }
        func describe(_ line: RoleLine?) -> String {
            guard let line else { return "unknown" }
            return line.role == .coding && line.source == .sameAsConversation ? line.source.label : "\(line.model) (\(line.source.label))"
        }
        var text = "\(row.name): roles conversation \(describe(row.conversation)) | coding threads \(describe(row.coding)) | sub-agents \(row.subAgents), set on the box"
        if let blocked = row.blocked { text += " | \(blocked.text)" }
        return text
    }
}

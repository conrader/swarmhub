import Foundation

/// The pair "Switch this chat" and "Switch existing chats…" lock a main chat to, with the origin recorded on it.
enum LockTarget: Equatable, Sendable {
    case pair(ModelChoice, LockOrigin?)
    case refused(String)
}

extension ModelPolicy {
    /// The bot's resolved Conversation pair, else the agent's current default pair (Hermes has no unpin). A bot's own
    /// pick its list lacks is refused; a default the list lacks falls to the agent default, as a new chat would.
    static func lockTarget(settings: BotModelSettings?, defaults: ModelDefaults?, catalog: ModelCatalog?) -> LockTarget {
        let effective = effective(role: .conversation, settings: settings, defaults: defaults, catalog: catalog)
        if effective.check == .notOffered, effective.resolved.source == .bot, let note = effective.note { return .refused(note) }
        let origin: LockOrigin? = switch effective.source {
        case .bot: .bot
        case .appDefault: .torvliDefault
        default: settings?.conversation == .box ? .bot : nil
        }
        if let choice = effective.choice { return .pair(choice, origin) }
        guard let provider = catalog?.defaultSupplierRow?.slug, let model = catalog?.agentDefault?.model,
              let pair = ModelChoice(provider: provider, model: model) else { return .refused(ModelRoleReason.noList.text) }
        return .pair(pair, origin)
    }
}

/// P13 Part D, Settings → Models → **Switch existing chats…**: from → to per bot, or why a bot is skipped. Main chats
/// only (group member sessions and threads are never touched). Pure: no SwiftUI, no network.
struct ModelRolesPlan: Equatable, Sendable {
    enum Skip: Equatable, Sendable {
        case alreadyOn, noSession, handPick(String), notOffered(String), cannotSwitch(String), streaming, notLoaded

        var text: String {
            switch self {
            case .alreadyOn: "already on it"
            case .noSession: "no chat yet; a new chat starts on its model"
            case .handPick(let model): "keeps the model you picked (\(model))"
            case .notOffered(let text), .cannotSwitch(let text): text
            case .streaming: "is answering; try again when it is done"
            case .notLoaded: "models not loaded; press Load first"
            }
        }
    }

    struct Input: Sendable {
        let id: UUID; let name: String
        var block: String?
        var sessionID: String?
        var isStreaming = false
        var lock: HermesModelLock?
        var current: CurrentModel?
        var catalog: Loadable<ModelCatalog> = .loading
        var blocker: ModelRoleReason?
        var settings: BotModelSettings?
        var defaults: ModelDefaults?
    }

    struct Row: Equatable, Sendable, Identifiable {
        let id: UUID; let name: String
        var from: String?
        var to: ModelChoice?
        var origin: LockOrigin?
        var skip: Skip?
        var willChange: Bool { skip == nil && to != nil }
        /// "a → b", or the skip reason.
        var text: String {
            if let skip { return skip.text }
            return "\(from ?? "unknown") → \(to?.model ?? "unknown")"
        }
    }

    var rows: [Row]
    init(_ inputs: [Input]) { rows = inputs.map(Self.row) }

    var changing: [Row] { rows.filter(\.willChange) }
    /// "14 of 16 would change", shown on the button.
    var countText: String { "\(changing.count) of \(rows.count) would change" }

    static func row(_ input: Input) -> Row {
        var row = Row(id: input.id, name: input.name, from: input.current?.model)
        func skip(_ reason: Skip) -> Row { row.skip = reason; return row }
        if let block = input.block { return skip(.cannotSwitch(block)) }
        if input.isStreaming { return skip(.streaming) }
        guard let sessionID = input.sessionID else { return skip(.noSession) }
        let catalog: ModelCatalog
        switch input.catalog {
        case .loading: return skip(.notLoaded)
        case .unavailable(let reason), .failed(let reason): return skip(.cannotSwitch(reason))
        case .loaded(let loaded): catalog = loaded
        }
        if let blocker = input.blocker { return skip(.cannotSwitch(blocker.text)) }
        if catalog.pinning != .permanent { return skip(.cannotSwitch(ModelCatalog.switchingLater)) }
        if let lock = input.lock, lock.sessionID == sessionID, lock.origin == nil { return skip(.handPick(lock.model)) }
        switch ModelPolicy.lockTarget(settings: input.settings, defaults: input.defaults, catalog: catalog) {
        case .refused(let reason): return skip(.notOffered(reason))
        case .pair(let pair, let origin):
            row.to = pair; row.origin = origin
            if let current = input.current, ModelCatalog.sameModel(current.model, pair.model) { return skip(.alreadyOn) }
            return row
        }
    }
}

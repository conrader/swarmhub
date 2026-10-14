import Foundation

/// P12: what one OpenClaw connection can do, from `hello-ok` only (never a version): a feature is available when its
/// method is in `features.methods` and its scope is in `auth.scopes`. `features.methods` is conservative and parameters
/// are newer than methods, so an optional call or parameter the Gateway rejects (`INVALID_REQUEST`, unknown method)
/// marks only that feature unavailable for the connection (`unsupported`), never the whole action.
enum OpenClawFeature: String, CaseIterable, Sendable {
    case agents, chat, stop, steer, history, sessions, threads, attachments, approvals, models, sessionTitles

    var method: String {
        switch self {
        case .agents: "agents.list"
        case .chat, .steer, .attachments: "chat.send"
        case .stop: "chat.abort"
        case .history: "chat.history"
        case .sessions: "sessions.list"
        case .threads, .sessionTitles: "sessions.create"
        case .approvals: "exec.approval.resolve"
        case .models: "models.list"
        }
    }

    /// The one method-to-scope table (the schema's `scope` per method; `sessions.create` is `dynamic` there and needs
    /// `operator.write` for the plain forms used here).
    var scope: String {
        switch self {
        case .agents, .history, .sessions, .models: "operator.read"
        case .chat, .stop, .steer, .attachments, .threads, .sessionTitles: "operator.write"
        case .approvals: "operator.approvals"
        }
    }

    var label: String {
        switch self {
        case .agents: "List agents"
        case .chat: "Chat"
        case .stop: "Stop"
        case .steer: "Steer"
        case .history: "History"
        case .sessions: "Session list"
        case .threads: "Reply in thread"
        case .attachments: "Images"
        case .approvals: "Approvals"
        case .models: "Model list"
        case .sessionTitles: "Session titles"
        }
    }
}

struct OpenClawCapabilities: Sendable, Equatable {
    let summary: GatewaySummary
    /// Features this connection rejected at runtime (an optional parameter or call the Gateway does not know).
    var unsupported: Set<OpenClawFeature> = []

    func isAvailable(_ feature: OpenClawFeature) -> Bool { reason(feature) == nil }

    /// Why a feature is unavailable, in plain words; nil when it is available.
    func reason(_ feature: OpenClawFeature) -> String? {
        if !summary.methods.contains(feature.method) { return "This Gateway does not offer \(feature.method)." }
        if !summary.hasScope(feature.scope) { return "This Mac lacks \(feature.scope) on the Gateway." }
        if unsupported.contains(feature) { return "This Gateway rejected the \(feature.label.lowercased()) request; update OpenClaw to use it." }
        return nil
    }

    /// The Hermes-named flags the UI gates on: `chat.send` gives streaming and steer, `sessions.create` gives fork.
    var hermesFlags: Set<String> {
        var flags: Set<String> = []
        if isAvailable(.chat) { flags.insert("session_chat_streaming") }
        if isAvailable(.steer) { flags.insert("run_steer") }
        if isAvailable(.threads) { flags.insert("session_fork") }
        return flags
    }

    /// The Overview's rows: every feature with its reason.
    var rows: [(feature: OpenClawFeature, reason: String?)] { OpenClawFeature.allCases.filter { $0 != .sessionTitles }.map { ($0, reason($0)) } }
}

/// Runtime marks per Gateway, reset when the connection changes (`connId`).
actor OpenClawRuntimeMarks {
    private var marks: [String: (connId: String, features: Set<OpenClawFeature>)] = [:]

    func unsupported(gatewayID: String, connId: String) -> Set<OpenClawFeature> {
        guard let entry = marks[gatewayID], entry.connId == connId else { return [] }
        return entry.features
    }

    func mark(_ feature: OpenClawFeature, gatewayID: String, connId: String) {
        var entry: (connId: String, features: Set<OpenClawFeature>) = marks[gatewayID].flatMap { $0.connId == connId ? $0 : nil } ?? (connId, [])
        entry.features.insert(feature); marks[gatewayID] = entry
    }
}

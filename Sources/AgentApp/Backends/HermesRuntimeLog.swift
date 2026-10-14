import Foundation

/// What Hermes reported a turn ran on: the `runtime{}` object of `run.started`, `assistant.completed` and
/// `run.completed` on the session stream (0.20.5 and 0.21.x). Only the model id and provider slug are kept.
struct HermesRuntime: Equatable, Sendable {
    let model: String; let provider: String?

    /// Events that carry `runtime{}`.
    static let events: Set<String> = ["run.started", "assistant.completed", "run.completed"]

    /// `{}`, a missing or empty model, wrong types or unusable ids mean no state, never an error.
    static func parse(_ value: Any?) -> HermesRuntime? {
        guard let runtime = value as? [String: Any], let model = runtime["model"] as? String, HermesModelCatalog.isUsableID(model) else { return nil }
        let provider = (runtime["provider"] as? String).flatMap { HermesModelCatalog.isUsableID($0) ? $0 : nil }
        return .init(model: model, provider: provider)
    }

    /// Whether this is the pair that was asked for (ids compared like `HermesModelOptions.sameModel`; a missing
    /// provider is not a match).
    func matches(provider wanted: String, model id: String) -> Bool {
        HermesModelOptions.sameModel(model, id) && provider?.lowercased() == wanted.lowercased()
    }
}

/// The last `runtime{}` seen per Hermes session, in memory only (like `HermesRunRegistry`), so `AgentEvent` and its
/// switches stay untouched. Nothing is persisted.
actor HermesRuntimeLog {
    static let shared = HermesRuntimeLog()
    private var values: [String: HermesRuntime] = [:]
    func record(_ runtime: HermesRuntime, for sessionID: String) { values[sessionID] = runtime }
    func last(for sessionID: String) -> HermesRuntime? { values[sessionID] }
}

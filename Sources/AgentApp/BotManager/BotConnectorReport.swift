import Foundation

/// Last observed bot load, separate from the enabled builtin toolsets in /v1/toolsets.
/// Persist failures and their scope so a relaunch cannot silently clear them or move them to another bot.
struct BotConnectorReport: Codable, Equatable, Sendable {
    struct Connector: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Sendable { case loaded, failed, neverAttempted = "never_attempted", unknown, disabled }
        var id: String { name }
        let name: String
        let state: State
        let toolCount: Int?
        let detail: String
        let observedAt: Date?

        var status: String {
            switch state {
            case .loaded: "Loaded \(toolCount ?? 0) tools"
            case .failed: "Failed"
            case .neverAttempted: "Never attempted"
            case .unknown: "Load state unknown"
            case .disabled: "Disabled"
            }
        }

        init(name: String, state: State, toolCount: Int? = nil, detail: String, observedAt: Date? = nil) {
            self.name = name; self.state = state; self.toolCount = toolCount; self.detail = detail; self.observedAt = observedAt
        }

        init?(_ row: [String: Any]) {
            guard let name = row["name"] as? String, HermesKeyPaste.isValidProfileName(name),
                  let raw = row["state"] as? String, let state = State(rawValue: raw),
                  let detail = row["detail"] as? String, !detail.isEmpty, detail.count <= 500 else { return nil }
            let count = row["tool_count"] as? Int
            if state == .loaded { guard let count, (0...100_000).contains(count) else { return nil } }
            self.init(name: name, state: state, toolCount: state == .loaded ? count : nil, detail: detail,
                      observedAt: (row["observed_at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
    }

    let scope: String
    let checkedAt: Date
    let connectors: [Connector]
}

enum BotConnectorCheck {
    static func instructions(backend: BackendKind, name: String) -> String? {
        guard HermesKeyPaste.isValidProfileName(name), let helper = BotManagerText.connectorHelper else { return nil }
        let kind = backend == .openClaw ? "openclaw" : "hermes"
        return """
        Read-only connector diagnosis for this bot only. Run the exact command below in your terminal.
        Do not edit files, install software, change configuration, restart anything, or call any connector tools.
        The helper reads config, registration logs and the saved model-facing catalog (including deferred tools).
        On OpenClaw it only lists MCPorter tool schemas, with interactive OAuth disabled.
        Return its exact JSON in a single ```swarmhub block. Do not infer status or echo config, logs or secrets.
        If terminal access is unavailable, return {"op":"connectors","name":"\(name)","list":[{"name":"defaults","state":"failed","detail":"Terminal access is unavailable; connector status could not be read."}]}.
        ```sh
        python3 - inspect \(kind) '\(name)' <<'SWARMHUB_CONNECTORS'
        \(helper)
        SWARMHUB_CONNECTORS
        ```
        """
    }
}

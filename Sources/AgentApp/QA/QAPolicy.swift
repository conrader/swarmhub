#if DEBUG
import Foundation

enum QAError: Error { case refused, blocked }

/// Independent app-side authority. Neither catalog edits nor model output extend this policy.
enum QAPolicy {
    static let schema = "swarmhub-qa/1"
    static let marker = "[QA-TEST]"
    static let prompts = [
        "marker": "Reply with exactly the supplied QA marker. Do not use tools.",
        "list": "Return a three-item QA list with an expected result per item. Do not use tools.",
        "wait": "Use only qa_wait for 2 seconds, then return the supplied QA marker.",
        "approval": "Request qa_approval for the supplied QA marker; do not use any other tool."
    ]
    // Expose only implemented primitives. Unsupported scenario capabilities stay blocked.
    static let operations: Set<String> = ["chat.send", "chat.stop", "approval.request", "approval.decide",
        "routine.create", "routine.run", "routine.pause", "routine.delete", "checkpoint", "restart.prepare"]
    static func identifier(_ text: String) -> Bool {
        text.range(of: #"\A[A-Za-z0-9-]{1,100}\z"#, options: .regularExpression) != nil
    }
    static func name(_ text: String) -> Bool {
        text.range(of: #"\AQA-[A-Za-z0-9-]{1,100} \[QA-TEST\]\z"#, options: .regularExpression) != nil
    }
    static func fields(_ value: ComposioValue, allowed: Set<String>, required: Set<String> = []) throws {
        guard let object = value.object, Set(object.keys).isSubset(of: allowed), required.isSubset(of: Set(object.keys)) else { throw QAError.refused }
    }
    static func step(_ value: ComposioValue) throws -> String {
        try fields(value, allowed: ["op", "prompt", "value"], required: ["op"])
        guard let op = value["op"].string, operations.contains(op) else { throw QAError.refused }
        let choices: [String: Set<String>] = ["chat.send": ["marker", "list", "wait"], "approval.request": ["approval"], "routine.create": ["marker"]]
        if let choices = choices[op] {
            guard let prompt = value["prompt"].string, choices.contains(prompt) else { throw QAError.refused }
        } else if value.object?["prompt"] != nil { throw QAError.refused }
        if op == "approval.decide" {
            guard let choice = value["value"].string, ["approve", "deny"].contains(choice) else { throw QAError.refused }
        } else if value.object?["value"] != nil { throw QAError.refused }
        return op
    }
    static func text(_ step: ComposioValue, resource: String) throws -> String {
        _ = try self.step(step)
        guard name(resource), let key = step["prompt"].string, let prompt = prompts[key] else { throw QAError.refused }
        return marker + " " + resource + " " + prompt
    }

    /// Strict typed checks: JSON 1 never stands in for true. Missing inventory is unsafe.
    static func attestation(_ value: ComposioValue, nonce: String, now: Double = Date().timeIntervalSince1970) throws {
        guard value["schema"] == .string(schema), value["nonce"] == .string(nonce) else { throw QAError.refused }
        for key in ["debug_build", "test_mode", "real_app", "real_hermes", "isolated_qa_store", "inventory_complete",
                    "sandbox_enforced_app", "sandbox_enforced_hermes", "default_deny_tools", "egress_denied_except_model",
                    "qa_peers_only", "qa_marker_propagated", "watchdog_active"] {
            guard value[key] == .bool(true) else { throw QAError.refused }
        }
        guard value["real_connector_count"] == .number(0), value["production_jobs_accessible"] == .bool(false),
              case .number(let expiry) = value["expires_at"], expiry.isFinite, expiry > now, expiry <= now + 60 else { throw QAError.refused }
        for key in ["build", "commit", "hermes_version", "sandbox_policy_digest", "lease"] {
            guard let text = value[key].string, !text.isEmpty, text.utf8.count <= 200 else { throw QAError.refused }
        }
        guard value["lease"].string?.range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil else { throw QAError.refused }
        guard let inventory = value["connectors"].array, !inventory.isEmpty else { throw QAError.refused }
        var names: Set<String> = []
        for item in inventory {
            guard let name = item["name"].string, !name.isEmpty, names.insert(name).inserted,
                  item["implementation"] == .string("record-only"), item["has_credentials"] == .bool(false),
                  item["network_enabled"] == .bool(false) else { throw QAError.refused }
        }
        // Exhaustiveness is a server enforcement obligation; these mandatory classes prevent trivial omission.
        guard Set(["email", "slack", "whatsapp", "connected-apps", "terminal", "browser", "http", "coding", "peers", "background"]).isSubset(of: names),
              let capabilities = value["capabilities"].array, capabilities.allSatisfy({ $0.string != nil }) else { throw QAError.refused }
    }
}
#endif

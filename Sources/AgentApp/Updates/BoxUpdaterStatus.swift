import Foundation

/// Readings come from a matched fixed-path status call or a failed staging call's diagnostic receipt.
/// Assistant text and skills_installed never enter this path. The bot-account boundary still applies (§3.5).
struct BoxUpdaterStatus: Decodable, Sendable {
    struct Bundle: Decodable, Sendable { let bundle_version: Int64; let manifest_sha256: String }
    struct Last: Decodable, Sendable {
        let command: String; let verdict: String; let bundle_version: Int64?
        let reason: String?; let detail: String?
    }
    struct Profile: Decodable, Sendable {
        let status: String?
        let advertised: [String: String?]
        let variants: [String: String]?
        /// Skill dev mode: skills the updater keeps because the bot modified them (absent while dev mode is off).
        var modified: [String]? = nil
    }
    struct Pins: Decodable, Sendable { let path: String; let protected: Bool }
    struct Pending: Decodable, Sendable {
        struct Component: Decodable, Sendable {
            let name: String; let version: String; let kind: String
            let waits_for: [String]?
        }
        let bundle_version: Int64
        let code: [Component]
        let data: [Component]
    }
    let schema: String
    let state: String
    let detail: String
    let bundle: Bundle?
    let last: Last?
    let profiles: [String: Profile]
    let reload_pending: Bool
    let pins: Pins
    var pending_confirm: Pending? = nil
    var applied_bundle_version: Int64? = nil
    var confirmed_version: Int64? = nil

    /// App diagnostic overlay: preserve the last known live versions, but never reuse an acceptance verdict.
    static func failure(_ detail: String, state: String = "failed", previous: Self?) -> Self {
        Self(schema: "swarmhub/update-status/1", state: state, detail: detail, bundle: previous?.bundle,
             last: nil, profiles: previous?.profiles ?? [:], reload_pending: previous?.reload_pending ?? false,
             pins: previous?.pins ?? Pins(path: "/usr/local/lib/swarmhub-update/pins.json", protected: false))
    }

    static func failedResult(_ output: String, previous: Self?) -> Self {
        let output = commandOutput(output)
        let status = decode(output)
        let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
        let reason = status?.last?.reason ?? (object["reason"] as? String)
        let detail = status?.last?.detail ?? (object["detail"] as? String) ?? reason ?? "Updater returned a nonzero exit."
        let rejected = status?.last?.verdict == "reject" || (object["verdict"] as? String) == "reject"
        let rejectionDetail = status?.last?.detail ?? (status == nil ? object["detail"] as? String : nil)
        let message = rejected ? "Updater rejected: \(reason ?? detail)" +
            (rejectionDetail.map { $0 == reason ? "" : ". " + $0 } ?? "") : detail
        let state = status?.state ?? (object["state"] as? String) ?? "failed"
        return failure(message, state: !rejected && ["deferred", "failed", "recovery_pending"].contains(state) ? state : "failed",
                       previous: status ?? previous)
    }

    /// Diagnostic readings may report a newer bundle even when apply refuses an old click. Unwrapping a failed
    /// command is safe for observation only; acceptance must still use decode on the original terminal result.
    static func commandOutput(_ output: String) -> String {
        if let wrapper = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
           let stdout = (wrapper["output"] ?? wrapper["stdout"]) as? String { return stdout }
        return output
    }

    static func decode(_ output: String) -> Self? {
        guard output.utf8.count <= 1_048_576 else { return nil }
        var bytes = Data(output.utf8)
        // Hermes terminal tools may wrap stdout in their own result object. Never scan prose for JSON.
        if let wrapper = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
           let stdout = (wrapper["output"] ?? wrapper["stdout"]) as? String {
            if let exit = wrapper["exit_code"] as? Int, exit != 0 { return nil }
            bytes = Data(stdout.utf8)
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: bytes), value.schema == "swarmhub/update-status/1",
              value.pins.protected, value.pins.path == "/usr/local/lib/swarmhub-update/pins.json" else { return nil }
        return value
    }

    func accepted(_ package: StagedInstall.Package) -> Bool {
        bundle?.bundle_version == package.floor.bundle && bundle?.manifest_sha256 == package.floor.manifest &&
        last?.command == "apply --staged" && last?.verdict == "accept" && last?.bundle_version == package.floor.bundle &&
        ["current", "pending_confirm"].contains(state)
    }
}

/// A result must be paired to the exact status command in this turn, via the server's tool call id. Legacy
/// streams without results cannot verify an install; they leave the prior record alone.
struct UpdaterStatusCall {
    private var callID: String?
    mutating func consume(_ tool: ToolEvent) -> BoxUpdaterStatus? {
        guard ["terminal", "shell", "execute", "bash"].contains(tool.name) else { return nil }
        if tool.phase == .started, tool.command == StagedInstall.statusCommand { callID = tool.callID; return nil }
        guard let expected = callID, tool.callID == expected, tool.phase == .completed || tool.phase == .failed else { return nil }
        callID = nil
        guard tool.phase == .completed, let output = tool.result else { return nil }
        return BoxUpdaterStatus.decode(output)
    }
}

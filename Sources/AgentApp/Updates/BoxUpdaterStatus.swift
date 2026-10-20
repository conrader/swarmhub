import Foundation

/// Only terminal output from a separately matched fixed-path `status` call is decoded here. Assistant text and
/// skills_installed operations never enter this path. Status remains subject to the bot-account boundary (§3.5).
struct BoxUpdaterStatus: Decodable, Sendable {
    struct Bundle: Decodable, Sendable { let bundle_version: Int64; let manifest_sha256: String }
    struct Last: Decodable, Sendable { let command: String; let verdict: String; let bundle_version: Int64? }
    struct Profile: Decodable, Sendable {
        let status: String?
        let advertised: [String: String?]
        let variants: [String: String]?
    }
    struct Pins: Decodable, Sendable { let path: String; let protected: Bool }
    let schema: String
    let state: String
    let detail: String
    let bundle: Bundle?
    let last: Last?
    let profiles: [String: Profile]
    let reload_pending: Bool
    let pins: Pins

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

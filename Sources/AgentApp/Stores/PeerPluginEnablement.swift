import Foundation

/// Plugin files and Hermes PM admission are separate outcomes. Never bypass PM with config.yaml writes.
enum PeerPluginEnablement {
    static let marker = "SWARMHUB_PEER_ENABLE:"
    static let installInstructions = """
    Record skills_installed for files successfully written even if peer-plugin enablement is blocked. The peer command \
    must run as its own terminal tool call; it installs the plugin, attempts enablement once, and verifies it with hermes -p <profile> plugins list. \
    If enable exits nonzero or the list does not show swarmhub-peer enabled, report that held delivery is inactive. \
    PermissionError or dependency-sync failure in Hermes PM's sealed-core workspace needs the box operator; \
    do not retry, edit plugins.enabled/config.yaml, or ask for a gateway reload in that state. \
    Only after enablement is verified may you mention a gateway plugin reload is still needed; never claim held delivery is active from installation alone.
    """

    static func command(profile: String) -> String {
        let folder = SkillLibrary.installPath("swarmhub-messages", profile: profile)
        return """
        python3 - <<'SWARMHUB_PEER_ENABLE'
        import json, pathlib, subprocess
        subprocess.run(['python3', str(pathlib.Path('\(folder)/scripts/peer-runtime.py').expanduser()), 'install', '\(profile)'], check=True)
        enable = subprocess.run(['hermes', '-p', '\(profile)', 'plugins', 'enable', 'swarmhub-peer'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        listing = subprocess.run(['hermes', '-p', '\(profile)', 'plugins', 'list'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print('\(marker)' + json.dumps({'profile': '\(profile)', 'enable_exit': enable.returncode, 'list_exit': listing.returncode, 'enable_output': enable.stdout[-16384:], 'list_output': listing.stdout[-16384:]}))
        SWARMHUB_PEER_ENABLE
        """
    }

    struct Receipt: Decodable, Equatable {
        let profile: String
        let enable_exit: Int
        let list_exit: Int
        let enable_output: String
        let list_output: String

        var verified: Bool {
            enable_exit == 0 && list_exit == 0 && list_output.split(whereSeparator: \.isNewline).contains { line in
                let line = line.lowercased()
                return line.contains("swarmhub-peer") && line.contains("enabled") &&
                    !["disabled", "not enabled", "false"].contains { line.contains($0) }
            }
        }

        var result: SkillInstallResult {
            if verified {
                return .init(status: .installed, detail: "Skills installed; peer plugin enabled. Held delivery still requires a gateway plugin reload.")
            }
            if PeerPluginEnablement.isPMBlocked(enable_output + "\n" + list_output) {
                return .init(status: .peerEnableBlocked, detail: PeerPluginEnablement.blockedDetail)
            }
            return .init(status: .peerEnableUnverified,
                         detail: "Peer plugin installed; enablement not verified (enable exit \(enable_exit), list exit \(list_exit)). Held delivery is inactive; needs box operator. Do not reload the gateway yet.")
        }
    }

    static let blockedDetail = "Peer plugin installed, enable blocked by Hermes PM (sealed core) — needs box operator. Held delivery is inactive; a gateway reload cannot fix PM admission."

    static func isPMBlocked(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("permissionerror") || text.contains("permission denied") ||
            text.contains("filesystem permissions") || text.contains("dependency-sync") || text.contains("dependency sync") ||
            text.contains("sync_venv") || text.contains("sealed core") || text.contains("sealed-core")
    }

    /// Legacy servers may omit tool results; still preserve an explicit blocked report without calling it an install failure.
    static func reportedBlock(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["swarmhub-peer", "peer plugin", "peer-plugin"].contains { text.contains($0) } && isPMBlocked(text)
    }

    struct Call {
        var id: String?
        var profile: String?
        var receipt: Receipt?

        mutating func consume(_ tool: ToolEvent, profiles: Set<String>) {
            guard ["terminal", "shell", "execute", "bash"].contains(tool.name) else { return }
            if tool.phase == .started, let profile = profiles.first(where: { tool.command == PeerPluginEnablement.command(profile: $0) }) {
                id = tool.callID; self.profile = profile; receipt = nil
                return
            }
            guard let id, tool.callID == id, tool.phase == .completed || tool.phase == .failed else { return }
            self.id = nil
            guard let output = tool.result else { return }
            let stdout = BoxUpdaterStatus.commandOutput(output)
            for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix(PeerPluginEnablement.marker) {
                if let value = try? JSONDecoder().decode(Receipt.self, from: Data(line.dropFirst(PeerPluginEnablement.marker.count).utf8)),
                   value.profile == profile { receipt = value }
            }
        }
    }
}

extension AppStore {
    func notePeerEnableTool(_ tool: ToolEvent, manager: Bot) {
        guard let checks = pendingSkillChecks[manager.id] else { return }
        let profiles = Set(checks.filter { $0.skill == "swarmhub-messages" }.map(\.profile))
        peerEnableCalls[manager.id, default: .init()].consume(tool, profiles: profiles)
    }
}

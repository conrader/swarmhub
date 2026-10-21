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

    /// 0.6.4: one call for an all-bots batch (each `hermes plugins` call is a full Hermes CLI start, 7-17 s on the box).
    /// Plugin files are installed and the worker started for every profile; enable and list stop after the first
    /// PM-blocked profile (the block is the box's sealed core, the same for every profile), and `skipEnable` (PM blocked
    /// this connection recently) skips them from the start. A skipped profile's receipt says so. One profile without a
    /// skip is the single-bot command, byte for byte.
    static func command(profiles: [String], skipEnable: Bool) -> String {
        if profiles.count == 1, !skipEnable { return command(profile: profiles[0]) }
        let rows = profiles.map { "('\($0)', '\(SkillLibrary.installPath("swarmhub-messages", profile: $0))/scripts/peer-runtime.py')" }
        return """
        python3 - <<'SWARMHUB_PEER_ENABLE'
        import json, pathlib, subprocess
        blocked = \(skipEnable ? "True" : "False")
        signs = (\(pmBlockSigns.map { "'\($0)'" }.joined(separator: ", ")))
        def run(*args):
            return subprocess.run(list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for profile, script in [\(rows.joined(separator: ", "))]:
            script = str(pathlib.Path(script).expanduser())
            receipt = {'profile': profile, 'enable_exit': -1, 'list_exit': -1, 'enable_output': '', 'list_output': '', 'skipped': blocked}
            setup = run('python3', script, 'install', profile)
            if setup.returncode != 0:
                receipt.update(enable_exit=setup.returncode, enable_output='peer-runtime install failed: ' + setup.stdout[-4096:], skipped=False)
            elif not blocked:
                enable = run('hermes', '-p', profile, 'plugins', 'enable', 'swarmhub-peer')
                listing = run('hermes', '-p', profile, 'plugins', 'list')
                receipt.update(enable_exit=enable.returncode, list_exit=listing.returncode, enable_output=enable.stdout[-16384:], list_output=listing.stdout[-16384:])
                blocked = enable.returncode != 0 and any(sign in (enable.stdout + listing.stdout).lower() for sign in signs)
            run('python3', script, 'start')
            print('\(marker)' + json.dumps(receipt))
        SWARMHUB_PEER_ENABLE
        """
    }

    struct Receipt: Decodable, Equatable {
        let profile: String
        let enable_exit: Int
        let list_exit: Int
        let enable_output: String
        let list_output: String
        /// 0.6.4 batch command: enable was not attempted because PM blocked it on this box (earlier in the call or recently).
        var skipped: Bool? = nil

        var verified: Bool {
            enable_exit == 0 && list_exit == 0 && list_output.split(whereSeparator: \.isNewline).contains { line in
                let line = line.lowercased()
                return line.contains("swarmhub-peer") && line.contains("enabled") &&
                    !["disabled", "not enabled", "false"].contains { line.contains($0) }
            }
        }

        var result: SkillInstallResult {
            if skipped == true { return .init(status: .peerEnableBlocked, detail: PeerPluginEnablement.skippedDetail) }
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

    static let skippedDetail = "Peer plugin installed; enable not retried because Hermes PM (sealed core) blocked it on this box — needs box operator. Held delivery is inactive. Install on one bot retries it."

    /// What Hermes PM's sealed-core refusal looks like in enable/list output (also checked on the box by the batch command).
    static let pmBlockSigns = ["permissionerror", "permission denied", "filesystem permissions", "dependency-sync", "dependency sync",
                               "sync_venv", "sealed core", "sealed-core"]

    static func isPMBlocked(_ text: String) -> Bool {
        let text = text.lowercased()
        return pmBlockSigns.contains { text.contains($0) }
    }

    /// Legacy servers may omit tool results; still preserve an explicit blocked report without calling it an install failure.
    static func reportedBlock(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["swarmhub-peer", "peer plugin", "peer-plugin"].contains { text.contains($0) } &&
            (isPMBlocked(text) || text.contains("blocked by permission"))
    }

    /// The exact peer script may be a standalone call or part of one whole dev-mode skill block.
    static func matchesCommand(_ candidate: String, profile: String) -> Bool {
        let peer = command(profile: profile)
        if candidate == peer { return true }
        let definition = SkillDevMode.functionDefinition + "\n"
        let block = candidate.hasPrefix(definition) ? String(candidate.dropFirst(definition.count)) : candidate
        guard block.contains("\n" + peer + "\n") else { return false }
        func pattern(_ template: String) -> String {
            NSRegularExpression.escapedPattern(for: template.replacingOccurrences(of: "{profile}", with: profile)
                .replacingOccurrences(of: "{skill}", with: "swarmhub-messages"))
                .replacingOccurrences(of: NSRegularExpression.escapedPattern(for: "{bundled}"), with: "[0-9a-f]{64}")
        }
        return [(SkillDevMode.guardHead, SkillDevMode.guardTail), (SkillDevMode.resetHead, SkillDevMode.resetTail)].contains { head, tail in
            block.range(of: "\\A" + pattern(head) + "\n", options: .regularExpression) != nil &&
                block.range(of: "\n" + pattern(tail) + "\\z", options: .regularExpression) != nil
        }
    }

    struct Call {
        var id: String?
        var profile: String?
        var receipt: Receipt?
        /// Every profile's receipt this turn (an all-bots batch call prints one per profile).
        var receipts: [String: Receipt] = [:]
        var batch: [String] = []

        /// `batch`: the profiles of an all-bots turn in order, whose single peer call is `command(profiles:skipEnable:)`.
        mutating func consume(_ tool: ToolEvent, profiles: Set<String>, batch ordered: [String] = []) {
            guard ["terminal", "shell", "execute", "bash"].contains(tool.name) else { return }
            if tool.phase == .started, let command = tool.command {
                if let profile = profiles.first(where: { PeerPluginEnablement.matchesCommand(command, profile: $0) }) {
                    id = tool.callID; self.profile = profile; batch = []; receipt = nil
                    return
                }
                if !ordered.isEmpty, [false, true].contains(where: { PeerPluginEnablement.command(profiles: ordered, skipEnable: $0) == command }) {
                    id = tool.callID; profile = nil; batch = ordered; receipt = nil
                    return
                }
            }
            guard let id, tool.callID == id, tool.phase == .completed || tool.phase == .failed else { return }
            self.id = nil
            guard let output = tool.result else { return }
            let stdout = BoxUpdaterStatus.commandOutput(output)
            let expected = Set(batch.isEmpty ? profile.map { [$0] } ?? [] : batch)
            for line in stdout.split(whereSeparator: \.isNewline) where line.hasPrefix(PeerPluginEnablement.marker) {
                if let value = try? JSONDecoder().decode(Receipt.self, from: Data(line.dropFirst(PeerPluginEnablement.marker.count).utf8)),
                   expected.contains(value.profile) {
                    receipts[value.profile] = value
                    if batch.isEmpty { receipt = value }
                }
            }
        }
    }
}

extension AppStore {
    func notePeerEnableTool(_ tool: ToolEvent, manager: Bot) {
        guard let checks = pendingSkillChecks[manager.id] else { return }
        var ordered: [String] = []
        for check in checks where check.skill == "swarmhub-messages" && !ordered.contains(check.profile) { ordered.append(check.profile) }
        peerEnableCalls[manager.id, default: .init()].consume(tool, profiles: Set(ordered), batch: ordered)
    }
}

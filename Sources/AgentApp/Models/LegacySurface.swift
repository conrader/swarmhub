import Foundation

/// The app is moving to Herdr only. Until the Hermes and OpenClaw code is removed (a later, staged cleanup), their
/// parts of the surface are hidden behind this one switch: the setup window's Hermes and OpenClaw paths, the Backend
/// picker, and the Settings panes and sections that only serve a Hermes box or an OpenClaw Gateway. Nothing is deleted
/// and a bot that still runs on Hermes keeps working; turning the switch on (Settings → Advanced → Servers and keys)
/// brings every hidden control back.
enum LegacySurface {
    /// `UserDefaults`: true shows the Hermes and OpenClaw controls. Off by default.
    static let key = "showLegacyBackends"
    static func isShown(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }

    /// Advanced panes whose every control serves a Hermes box or an OpenClaw Gateway: models and roles, approval
    /// routing, connected apps, `/goal` and routine suggestions, heartbeats, orientation, usage, the SwarmHub
    /// service address and the reports inbox. A Herdr agent keeps its model, approvals and memory in its own program.
    static let panes: Set<SettingsLayout.AdvancedPane> = [.models, .review, .apps, .chats, .heartbeat, .orientation, .usage, .account, .reports]

    static func panes(showingLegacy: Bool) -> [SettingsLayout.AdvancedPane] {
        SettingsLayout.AdvancedPane.allCases.filter { showingLegacy || !panes.contains($0) }
    }
}

/// What a Herdr-only install is spared. With the switch off nothing of the older backends is shown: no Reports row,
/// inbox or "Report a Problem…", no list of a box's unconnected profiles, no Grok Bot import, no warning about the
/// prompt sync file. And while no bot runs on an older backend either, nothing is done for them at launch or in
/// the background: the Reports file is never opened and no box is probed, polled or sent a presence.
extension AppStore {
    /// A bot here still runs on Hermes or OpenClaw (a history-only one counts: it belongs to them).
    var hasOlderBackendBots: Bool { bots.contains { ($0.backend == .hermes || $0.backend == .openClaw) && !$0.isDemo } }

    /// The older backends still have work to do here: their surface is shown, or a bot still runs on one.
    var olderBackendsInUse: Bool { LegacySurface.isShown(defaults) || hasOlderBackendBots }

    /// The switch that brings the older backends' surface back is offered where there is something of theirs: it is
    /// on, a bot still runs on one, or their address or Gateway is saved. A Herdr-only install does not read about them.
    var offersOlderBackendsSwitch: Bool {
        olderBackendsInUse || defaults.object(forKey: "hermesBaseURL") != nil || !openClawGateways.isEmpty
    }
}

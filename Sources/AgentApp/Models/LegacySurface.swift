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

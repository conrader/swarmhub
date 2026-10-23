import Foundation

/// Where every Settings control lives after P21 (item 4): exactly one home each, the simple page or one Advanced pane.
/// The views read the panes from here; the tests assert that nothing was lost or duplicated.
enum SettingsLayout {
    enum Home: Equatable { case simple; case advanced(AdvancedPane) }

    /// Advanced: today's panes re-homed, Avatars folded into Appearance and alerts, nothing new.
    enum AdvancedPane: String, CaseIterable, Identifiable {
        case servers = "Servers and keys", alerts = "Appearance and alerts", models = "Models", review = "Approvals"
        case apps = "Connected apps"
        // P38 C: dictation's deAPI key and live voice's state.
        case voice = "Voice"
        // P45: the budget of a chat's /goal.
        case chats = "Chats"
        // P46: heartbeats, one Hermes routine per bot.
        case heartbeat = "Heartbeat"
        // P49: a new bot's orientation, its coordinator and the quiet hours.
        case orientation = "Orientation"
        case computers = "Computers", usage = "Usage", account = "Account", reports = "Reports", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .servers: "server.rack"
            case .alerts: "paintpalette"
            case .models: "cpu"
            case .review: "checkmark.shield"
            case .apps: "square.stack.3d.up"
            case .computers: "desktopcomputer"
            case .usage: "chart.bar"
            case .account: "person.crop.circle"
            case .reports: "tray"
            case .about: "info.circle"
            case .voice: "mic"
            case .chats: "bubble.left.and.bubble.right"
            case .heartbeat: "waveform.path.ecg"
            case .orientation: "flag"
            }
        }
    }

    /// P32 8: the words for where a pane is, e.g. "Settings → Advanced → Servers and keys".
    static func path(_ pane: AdvancedPane, _ section: String? = nil) -> String {
        (["Settings", "Advanced", pane.rawValue] + (section.map { [$0] } ?? [])).joined(separator: " → ")
    }

    /// Every control Settings had at the start of P21 (0.4.4), by stable id.
    static let baseline = [
        "servers.hermesVersion", "you.name", "servers.baseURL", "servers.defaultKey", "servers.namedProfiles", "servers.testDiscover",
        "servers.connectedProfiles", "servers.reenterKey", "servers.addFromBox", "servers.grokBot", "servers.openClaw",
        "appearance.theme", "appearance.accent", "alerts.avatarMotion", "notifications.master", "alerts.perAgent",
        "computers.list", "review.perAgent", "models.roles", "usage.table",
        "about.version", "about.build", "about.autoCheck", "about.autoDownload", "about.checkUpdates", "about.acknowledgements"
    ]
    /// New in P21: the simple page's connection controls and its way into Advanced.
    static let added = ["connection.status", "connection.test", "connection.setup", "advanced.open",
                        // P36: the SwarmHub service and the Reports inbox (P40: the sign-in entry is gone).
                        "account.serviceURL", "reports.list",
                        // P38 B: connected apps (ChatGPT, Composio apps and each bot's access, background app access).
                        "apps.chatgpt", "apps.composio", "apps.botAccess", "apps.background",
                        // P38 C: voice dictation (deAPI) and live voice with ChatGPT.
                        "voice.dictationKey", "voice.live",
                        // P45: /goal's budget (rounds and hours).
                        "chats.goalBudget",
                        // P46: the heartbeat template and each bot's heartbeat.
                        "heartbeat.template", "heartbeat.bots",
                        // P49: orientation for new bots (on/off, coordinator) and the quiet hours.
                        "orientation.newBots", "orientation.quietHours",
                        // Konrad 2026-10-22: the app icon (Light by default, Dark on request), apart from the theme.
                        "appearance.appIcon",
                        // alerts2: each server's alerts while SwarmHub is closed (ntfy, email, test, service state).
                        "alerts.offApp"]

    static let entries: [(id: String, home: Home)] = [
        ("connection.status", .simple), ("connection.test", .simple), ("connection.setup", .simple), ("you.name", .simple),
        ("appearance.theme", .simple), ("appearance.appIcon", .simple), ("appearance.accent", .simple), ("notifications.master", .simple),
        // Konrad (2026-10-14): the automatic-check toggle sits with Version and Check for Updates; the rest of Updates is Advanced.
        ("about.version", .simple), ("about.autoCheck", .simple), ("about.checkUpdates", .simple), ("advanced.open", .simple),
        ("servers.hermesVersion", .advanced(.servers)), ("servers.baseURL", .advanced(.servers)), ("servers.defaultKey", .advanced(.servers)),
        ("servers.namedProfiles", .advanced(.servers)), ("servers.testDiscover", .advanced(.servers)),
        ("servers.connectedProfiles", .advanced(.servers)), ("servers.reenterKey", .advanced(.servers)),
        ("servers.addFromBox", .advanced(.servers)), ("servers.grokBot", .advanced(.servers)), ("servers.openClaw", .advanced(.servers)),
        ("alerts.perAgent", .advanced(.alerts)), ("alerts.avatarMotion", .advanced(.alerts)), ("alerts.offApp", .advanced(.alerts)),
        ("models.roles", .advanced(.models)), ("review.perAgent", .advanced(.review)), ("computers.list", .advanced(.computers)),
        ("usage.table", .advanced(.usage)),
        // P36: the SwarmHub service address and the Reports inbox.
        ("account.serviceURL", .advanced(.account)), ("reports.list", .advanced(.reports)),
        ("apps.chatgpt", .advanced(.apps)), ("apps.composio", .advanced(.apps)), ("apps.botAccess", .advanced(.apps)), ("apps.background", .advanced(.apps)),
        ("voice.dictationKey", .advanced(.voice)), ("voice.live", .advanced(.voice)), ("chats.goalBudget", .advanced(.chats)),
        ("heartbeat.template", .advanced(.heartbeat)), ("heartbeat.bots", .advanced(.heartbeat)),
        ("orientation.newBots", .advanced(.orientation)), ("orientation.quietHours", .advanced(.orientation)),
        ("about.build", .advanced(.about)), ("about.autoDownload", .advanced(.about)), ("about.acknowledgements", .advanced(.about))
    ]

    static func home(of id: String) -> Home? { entries.first { $0.id == id }?.home }
    static var simpleIDs: [String] { entries.filter { $0.home == .simple }.map(\.id) }
    static func ids(in pane: AdvancedPane) -> [String] { entries.filter { $0.home == .advanced(pane) }.map(\.id) }

    /// An agent's settings (Part B): the simple part, then everything folded under Advanced.
    static let editorSimple = ["editor.avatar", "editor.name", "editor.instructions", "editor.notification", "editor.save"]
    static let editorAdvanced = ["editor.title", "editor.description", "editor.backend", "editor.showInSidebar", "editor.approvals",
                                 "editor.models", "editor.boxInstructions", "editor.canManage", "editor.runsOn"]
}

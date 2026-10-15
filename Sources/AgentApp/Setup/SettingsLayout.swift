import Foundation

/// Where every Settings control lives after P21 (item 4): exactly one home each, the simple page or one Advanced pane.
/// The views read the panes from here; the tests assert that nothing was lost or duplicated.
enum SettingsLayout {
    enum Home: Equatable { case simple; case advanced(AdvancedPane) }

    /// Advanced: today's panes re-homed, Avatars folded into Appearance and alerts, nothing new.
    enum AdvancedPane: String, CaseIterable, Identifiable {
        case servers = "Servers and keys", alerts = "Appearance and alerts", models = "Models", review = "Approvals"
        case apps = "Connected apps", computers = "Computers", usage = "Usage", account = "Account", reports = "Reports", about = "About"
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
                        // P36: the SwarmHub account and the Reports inbox.
                        "account.swarmhub", "account.serviceURL", "reports.list",
                        // P38 B: connected apps (ChatGPT, Composio apps and each bot's access, background app access).
                        "apps.chatgpt", "apps.composio", "apps.botAccess", "apps.background"]

    static let entries: [(id: String, home: Home)] = [
        ("connection.status", .simple), ("connection.test", .simple), ("connection.setup", .simple), ("you.name", .simple),
        ("appearance.theme", .simple), ("appearance.accent", .simple), ("notifications.master", .simple),
        // Konrad (2026-10-14): the automatic-check toggle sits with Version and Check for Updates; the rest of Updates is Advanced.
        ("about.version", .simple), ("about.autoCheck", .simple), ("about.checkUpdates", .simple), ("advanced.open", .simple),
        ("servers.hermesVersion", .advanced(.servers)), ("servers.baseURL", .advanced(.servers)), ("servers.defaultKey", .advanced(.servers)),
        ("servers.namedProfiles", .advanced(.servers)), ("servers.testDiscover", .advanced(.servers)),
        ("servers.connectedProfiles", .advanced(.servers)), ("servers.reenterKey", .advanced(.servers)),
        ("servers.addFromBox", .advanced(.servers)), ("servers.grokBot", .advanced(.servers)), ("servers.openClaw", .advanced(.servers)),
        ("alerts.perAgent", .advanced(.alerts)), ("alerts.avatarMotion", .advanced(.alerts)),
        ("models.roles", .advanced(.models)), ("review.perAgent", .advanced(.review)), ("computers.list", .advanced(.computers)),
        ("usage.table", .advanced(.usage)),
        // P36: the SwarmHub sign-in (sending reports only) and the Reports inbox.
        ("account.swarmhub", .advanced(.account)), ("account.serviceURL", .advanced(.account)), ("reports.list", .advanced(.reports)),
        ("apps.chatgpt", .advanced(.apps)), ("apps.composio", .advanced(.apps)), ("apps.botAccess", .advanced(.apps)), ("apps.background", .advanced(.apps)),
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

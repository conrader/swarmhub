import Foundation

/// Where every Settings control lives: exactly one home each, the simple page or one Advanced pane.
/// The views read the panes from here; the tests assert that nothing is listed twice or without a home.
enum SettingsLayout {
    enum Home: Equatable { case simple; case advanced(AdvancedPane) }

    enum AdvancedPane: String, CaseIterable, Identifiable {
        case servers = "Servers and keys", alerts = "Appearance and alerts"
        // Dictation's deAPI key.
        case voice = "Voice"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .servers: "server.rack"
            case .alerts: "paintpalette"
            case .about: "info.circle"
            case .voice: "mic"
            }
        }
    }

    /// The words for where a pane is, e.g. "Settings → Advanced → Servers and keys".
    static func path(_ pane: AdvancedPane, _ section: String? = nil) -> String {
        (["Settings", "Advanced", pane.rawValue] + (section.map { [$0] } ?? [])).joined(separator: " → ")
    }

    static let entries: [(id: String, home: Home)] = [
        ("connection.status", .simple), ("connection.test", .simple), ("connection.setup", .simple), ("you.name", .simple),
        ("appearance.theme", .simple), ("appearance.appIcon", .simple), ("appearance.accent", .simple), ("notifications.master", .simple),
        // The automatic-check toggle sits with Version and Check for Updates; the rest of Updates is Advanced.
        ("about.version", .simple), ("about.autoCheck", .simple), ("about.checkUpdates", .simple), ("advanced.open", .simple),
        ("servers.herdr", .advanced(.servers)), ("servers.helpers", .advanced(.servers)), ("servers.projects", .advanced(.servers)), ("servers.grokBot", .advanced(.servers)),
        ("alerts.perAgent", .advanced(.alerts)), ("alerts.avatarMotion", .advanced(.alerts)),
        ("voice.dictationKey", .advanced(.voice)),
        ("about.build", .advanced(.about)), ("about.autoDownload", .advanced(.about)), ("about.acknowledgements", .advanced(.about))
    ]

    static func home(of id: String) -> Home? { entries.first { $0.id == id }?.home }
    static var simpleIDs: [String] { entries.filter { $0.home == .simple }.map(\.id) }
    static func ids(in pane: AdvancedPane) -> [String] { entries.filter { $0.home == .advanced(pane) }.map(\.id) }

    /// An agent's settings: the simple part, then everything folded under Advanced.
    static let editorSimple = ["editor.avatar", "editor.name", "editor.instructions", "editor.notification", "editor.save"]
    static let editorAdvanced = ["editor.title", "editor.description", "editor.showInSidebar", "editor.herdrAgent", "editor.herdrProjects"]
}

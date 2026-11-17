import SwiftUI

/// Where every Settings control lives: exactly one home each, in one of the panes the Settings window lists in its
/// sidebar. There is one Settings, not a simple page with an "Advanced" behind it: General is what most people open
/// it for, and each other pane is one thing (the servers, dictation, the app itself).
/// The views read the panes from here; the tests assert that nothing is listed twice or without a home.
enum SettingsLayout {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", servers = "Servers"
        // Dictation's deAPI key.
        case voice = "Voice"
        // The app's version and each server's, and the one button when something is behind (`SoftwareUpdatePane`).
        case updates = "Software Update"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape.fill"
            case .servers: "server.rack"
            case .updates: "arrow.down.circle.fill"
            case .about: "info.circle.fill"
            case .voice: "mic.fill"
            }
        }
        /// The colour of the pane's tile in the sidebar.
        var colour: Color {
            switch self {
            case .general: AppColor.olive
            case .servers: AppColor.sage
            case .voice: AppColor.clay
            case .updates: AppColor.plum
            case .about: AppColor.sky
            }
        }
    }

    /// The words for where something is, e.g. "Settings → Servers → Projects".
    static func path(_ pane: Pane, _ section: String? = nil) -> String {
        (["Settings", pane.rawValue] + (section.map { [$0] } ?? [])).joined(separator: " → ")
    }

    static let entries: [(id: String, home: Pane)] = [
        ("you.name", .general), ("you.about", .general), ("appearance.theme", .general), ("appearance.accent", .general), ("appearance.appIcon", .general),
        ("appearance.avatarMotion", .general), ("notifications.master", .general),
        ("servers.herdr", .servers), ("servers.helpers", .servers), ("servers.skills", .servers), ("servers.projects", .servers), ("servers.grokBot", .servers),
        ("voice.dictationKey", .voice),
        ("updates.app", .updates), ("updates.autoCheck", .updates), ("updates.autoInstall", .updates), ("updates.servers", .updates),
        // About names the version and opens Software Update; everything else about updates is there.
        ("about.version", .about), ("about.checkUpdates", .about), ("about.build", .about), ("about.acknowledgements", .about)
    ]

    static func home(of id: String) -> Pane? { entries.first { $0.id == id }?.home }
    static func ids(in pane: Pane) -> [String] { entries.filter { $0.home == pane }.map(\.id) }

    /// A bot's settings: the simple part, then what is folded under Advanced. What a bot runs on (AI and model) is
    /// in its Details, under Model, and nowhere else.
    static let editorSimple = ["editor.avatar", "editor.name", "editor.instructions", "editor.notification", "editor.save"]
    static let editorAdvanced = ["editor.role", "editor.mainBot", "editor.messages", "editor.helpers", "editor.herdrProjects"]
}

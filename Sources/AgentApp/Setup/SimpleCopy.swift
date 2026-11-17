import Foundation

/// Every visible string of Settings' General pane, the simple part of a bot's settings and the empty state.
/// Plain words only, and "bots", as everywhere else in the app.
enum SimpleCopy {
    // Settings, simple page
    static let connection = "Connection"
    static let notConnected = "Not connected yet."
    static func connected(to place: String, agents count: Int) -> String {
        "Connected to \(place) · \(count == 1 ? "1 bot" : "\(count) bots")"
    }
    static let testConnection = "Check connection"
    static let testingConnection = "Checking…"
    static let setUp = "Set up…"
    static func connectedServers(_ servers: Int, agents count: Int) -> String {
        "Connected to \(servers) servers · \(count == 1 ? "1 bot" : "\(count) bots")"
    }
    static let addServer = "Add a server…"
    static let herdrCaption = "Where your bots run."
    static func serverSaid(_ name: String, _ line: String) -> String { "\(name): \(line)" }

    static let you = "You"
    static let yourName = "Your name"
    static let yourNameCaption = "What your bots and group chats call you."

    static let appearance = "Appearance"
    static let theme = "Theme"
    static let appIcon = "App icon"
    static let dark = "Dark", light = "Light", system = "System"
    static let accent = "Accent"
    static let accentCaption = "The colour of buttons and selections."
    static let appIconCaption = "Dark shows while the app itself is dark."

    static let notifications = "Notifications"
    static let notifyMaster = "Notify about new messages"
    static var notifyCaption: String { "When a reply arrives while \(AppConstants.name) is in the background." }
    static var notifyNeedsApp: String { "Notifications need \(AppConstants.name) to run as an installed app." }

    static let about = "About"
    static let version = "Version"
    static let autoCheck = "Automatically check for updates"
    static let checkForUpdates = "Check for Updates…"
    static let checkNow = "Check for updates"
    static let autoCheckCaption = "Checked once a day. You can install an update now or when you quit."
    static func openRelease(_ name: String) -> String { "Open \(name)" }

    static let previewOff = "Settings are off in preview."

    // Agent settings, simple part
    static let newAgent = "New bot"
    static let agentSettings = "Bot settings"
    static let avatar = "Avatar"
    static let name = "Name"
    static let instructions = "Instructions"
    static let herdrInstructionsCaption = "What it should know, and how it should work."
    static let herdrEditorAdvancedCaption = "Its role, and what it may do with other bots, helpers and projects."
    static let notifyAgent = "Notify me when it replies"
    static let cancel = "Cancel"
    static let save = "Save"
    static let editorAdvanced = "Advanced"

    // Empty state
    static let emptyTitle = "Meet your first bot"
    static let herdrEmptyDetail = "Set up takes a minute. Or look around with sample bots first."
    static let emptySetUp = "Set up"
    static let chooseTitle = "Who do you want to talk to?"
    static let chooseDetail = "Pick a bot on the left."
    static let sampleLabel = "Sample bot"

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        [connection, notConnected, connected(to: SetupCopy.thisMac, agents: 3), testConnection, testingConnection, setUp,
         connectedServers(2, agents: 3), addServer, herdrCaption, serverSaid("This Mac", "Connected."), you,
         yourName, yourNameCaption, appearance, theme, appIcon, dark, light, system, accent, accentCaption, appIconCaption, notifications, notifyMaster,
         notifyCaption, notifyNeedsApp, about, version, autoCheck, checkForUpdates, checkNow, autoCheckCaption, openRelease("1.0"),
         previewOff, newAgent, agentSettings, avatar, name, instructions,
         herdrInstructionsCaption, herdrEditorAdvancedCaption, herdrEmptyDetail, notifyAgent, cancel, save, editorAdvanced,
         emptyTitle, emptySetUp, chooseTitle, chooseDetail, sampleLabel]
    }
}

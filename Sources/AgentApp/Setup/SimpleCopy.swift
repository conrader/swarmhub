import Foundation

/// Every visible string of the simple Settings page, the simple part of an agent's settings and the empty state.
/// Plain words only, and "agents", never "bots".
enum SimpleCopy {
    // Settings, simple page
    static let connection = "Connection"
    static let notConnected = "Not connected yet."
    static func connected(to place: String, agents count: Int) -> String {
        "Connected to \(place) · \(count == 1 ? "1 agent" : "\(count) agents")"
    }
    static let testConnection = "Test connection"
    static let testingConnection = "Testing…"
    static let setUp = "Set up…"
    static func connectedServers(_ servers: Int, agents count: Int) -> String {
        "Connected to \(servers) servers · \(count == 1 ? "1 agent" : "\(count) agents")"
    }
    static let addServer = "Add a server…"
    static let herdrCaption = "Your agents run in Herdr, on this Mac or on a server you choose. Its access key stays on this Mac, in its secure storage."
    static func serverSaid(_ name: String, _ line: String) -> String { "\(name): \(line)" }

    static let you = "You"
    static let yourName = "Your name"
    static let yourNameCaption = "Shown in group chats; its first letter is the round button at the bottom of the sidebar."

    static let appearance = "Appearance"
    static let theme = "Theme"
    static let appIcon = "App icon"
    static let dark = "Dark", light = "Light", system = "System"
    static let accent = "Accent"
    static let accentCaption = "Dark is the default theme. The app icon is Light; pick Dark and it is dark while the app is dark. "
        + "The accent colours buttons, selections and usage bars; Graphite follows the text colour."

    static let notifications = "Notifications"
    static let notifyMaster = "Notify about new messages"
    static var notifyCaption: String { "Sent when a reply arrives while \(AppConstants.name) is in the background." }
    static var notifyNeedsApp: String { "Notifications need \(AppConstants.name) to run as an installed app." }

    static let about = "About"
    static let version = "Version"
    static let autoCheck = "Automatically check for updates"
    static let checkForUpdates = "Check for Updates…"
    static let checkNow = "Check for updates"
    static let autoCheckCaption = "Checked once a day. You can install an update now or when you quit."
    static func openRelease(_ name: String) -> String { "Open \(name)" }

    static let advanced = "Advanced…"
    static let herdrAdvancedCaption = "Servers and keys, alerts, voice and more."
    static let backToSimple = "‹ Simple settings"
    static let previewOff = "Settings are off in preview."

    // Agent settings, simple part
    static let newAgent = "New agent"
    static let agentSettings = "Agent settings"
    static let avatar = "Avatar"
    static let name = "Name"
    static let instructions = "What should it know or do?"
    static let herdrInstructionsCaption = "Given to this agent as its standing instructions each time it starts in Herdr."
    static let herdrEditorAdvancedCaption = "Title, the agent program and model, and what this agent may start."
    static let notifyAgent = "Notify me about this agent"
    static let cancel = "Cancel"
    static let save = "Save"
    static let editorAdvanced = "Advanced"

    // Empty state
    static let emptyTitle = "Connect your agents"
    static let herdrEmptyDetail = "Set up Herdr, where your agents run, or look around first."
    static let emptySetUp = "Set up"
    static let chooseTitle = "Choose an agent"
    static let chooseDetail = "Select an agent from the sidebar to begin."
    static let sampleLabel = "Sample, not real"

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        [connection, notConnected, connected(to: SetupCopy.thisMac, agents: 3), testConnection, testingConnection, setUp,
         connectedServers(2, agents: 3), addServer, herdrCaption, serverSaid("This Mac", "Connected."), you,
         yourName, yourNameCaption, appearance, theme, appIcon, dark, light, system, accent, accentCaption, notifications, notifyMaster,
         notifyCaption, notifyNeedsApp, about, version, autoCheck, checkForUpdates, checkNow, autoCheckCaption, openRelease("1.0"),
         advanced, herdrAdvancedCaption, backToSimple, previewOff, newAgent, agentSettings, avatar, name, instructions,
         herdrInstructionsCaption, herdrEditorAdvancedCaption, herdrEmptyDetail, notifyAgent, cancel, save, editorAdvanced,
         emptyTitle, emptySetUp, chooseTitle, chooseDetail, sampleLabel]
    }
}

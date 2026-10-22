import Foundation

/// Every visible string of the simple Settings page, the simple part of an agent's settings, the empty state and the
/// in-chat banners (P21). Plain words only: the same banned list as `SetupCopy`, and "agents", never "bots" (D12).
enum SimpleCopy {
    // Settings, simple page
    static let connection = "Connection"
    static let notConnected = "Not connected yet."
    static func connected(to place: String, agents count: Int) -> String {
        "Connected to \(place) · \(count == 1 ? "1 agent" : "\(count) agents")"
    }
    static let reenterKey = "An agent's key needs to be entered again: Advanced… → Servers and keys."
    static let testConnection = "Test connection"
    static let testingConnection = "Testing…"
    static let setUp = "Set up…"
    static let changeConnection = "Change connection…"
    static let connectionCaption = "Your agents live on a box you run. The key stays on this Mac, in its secure storage."
    static func tested(answered: Int, of total: Int) -> String {
        total == 0 ? "The box answered." : "The box answered. \(answered) of \(total) agents replied."
    }
    static func agentsNotAnswering(_ names: [String]) -> String { "Not answering: " + names.joined(separator: ", ") + "." }

    static let you = "You"
    static let yourName = "Your name"
    static let yourNameCaption = "Shown in group chats; its first letter is the round button at the bottom of the sidebar."

    static let appearance = "Appearance"
    static let theme = "Theme"
    static let appIcon = "App icon"
    static let dark = "Dark", light = "Light", system = "System"
    static let accent = "Accent"
    static let accentCaption = "Dark is the default theme. The app icon in the Dock is Light unless you pick Dark, whatever the theme. "
        + "The accent colours buttons, selections and usage bars; Graphite follows the text colour."

    static let notifications = "Notifications"
    static let notifyMaster = "Notify about new messages"
    static var notifyCaption: String { "Sent when a reply or a routine result arrives while \(AppConstants.name) is in the background." }
    static var notifyNeedsApp: String { "Notifications need \(AppConstants.name) to run as an installed app." }

    static let about = "About"
    static let version = "Version"
    static let autoCheck = "Automatically check for updates"
    static let checkForUpdates = "Check for Updates…"
    static let checkNow = "Check for updates"
    static let autoCheckCaption = "Checked once a day. You can install an update now or when you quit."
    static func openRelease(_ name: String) -> String { "Open \(name)" }

    static let advanced = "Advanced…"
    static let advancedCaption = "Servers and keys, approvals, models, computers, usage and more."
    static let backToSimple = "‹ Simple settings"
    static let previewOff = "Settings are off in preview."

    // Agent settings, simple part
    static let newAgent = "New agent"
    static let agentSettings = "Agent settings"
    static let avatar = "Avatar"
    static let name = "Name"
    static let instructions = "What should it know or do?"
    static let instructionsCaption = "Sent with every message as the agent's standing instructions. For an agent that runs on your box, leave empty to keep its own setup."
    static let notifyAgent = "Notify me about this agent"
    static let cancel = "Cancel"
    static let save = "Save"
    static let editorAdvanced = "Advanced"
    static let editorAdvancedCaption = "Title, approvals, models and how this agent is reached."
    static func runsOn(_ place: String, as name: String) -> String { "Runs on \(place) as \(name)" }

    // Empty state and banners
    static let emptyTitle = "Connect your agents"
    static let emptyDetail = "Connect the box where your agents run, or look around first."
    static let emptySetUp = "Set up"
    static let chooseTitle = "Choose an agent"
    static let chooseDetail = "Select an agent from the sidebar to begin."
    static let sampleLabel = "Sample, not real"
    static let historyOnly = "History only: this agent is not connected to your box yet."
    static let connect = "Connect…"
    static func noKey(_ name: String) -> String { "No key for \(name) yet." }
    static let addKey = "Add key"
    static func keyFor(_ name: String) -> String { "Key for \(name)" }

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        [connection, notConnected, connected(to: SetupCopy.thisMac, agents: 3), reenterKey, testConnection, testingConnection, setUp,
         changeConnection, connectionCaption, tested(answered: 2, of: 3), tested(answered: 0, of: 0), agentsNotAnswering(["Ada"]), you,
         yourName, yourNameCaption, appearance, theme, appIcon, dark, light, system, accent, accentCaption, notifications, notifyMaster,
         notifyCaption, notifyNeedsApp, about, version, autoCheck, checkForUpdates, checkNow, autoCheckCaption, openRelease("1.0"),
         advanced, advancedCaption, backToSimple, previewOff, newAgent, agentSettings, avatar, name, instructions,
         instructionsCaption, notifyAgent, cancel, save, editorAdvanced, editorAdvancedCaption, runsOn("this Mac", as: "Ada"),
         emptyTitle, emptyDetail, emptySetUp, chooseTitle, chooseDetail, sampleLabel, historyOnly, connect, noKey("Ada"), addKey, keyFor("Ada")]
    }
}

import Foundation

/// Every visible string of the off-app alerts section (Settings → Advanced → Appearance and alerts). Plain words.
enum AlertsCopy {
    static let title = "When SwarmHub is closed"
    static let caption = "Each server can send finished routines, code jobs, reports and webhook wakes to your phone (ntfy) or by email while SwarmHub is closed or you are away from this Mac."
    static let presenceNote = "While SwarmHub is open and you have used this Mac in the last 10 minutes, the box sends nothing: you see it here instead."
    static let noServers = "No server is connected yet."
    static let load = "Show status"
    static let loadCaption = "Reading the status runs one short command on the box."
    static let refresh = "Refresh"
    static let working = "Working…"
    static let ntfy = "ntfy"
    static let ntfyURL = "Topic URL"
    static let ntfyPlaceholder = "https://ntfy.sh/your-topic"
    static let ntfyToken = "Access token (optional)"
    static let email = "Email"
    static let emailHost = "SMTP server"
    static let emailPort = "Port"
    static let emailSecurity = "Security"
    static func security(_ value: AlertSettings.Security) -> String {
        switch value {
        case .starttls: "STARTTLS"
        case .ssl: "SSL"
        case .none: "None (relay on the box only)"
        }
    }
    static let emailUser = "User"
    static let emailPassword = "Password"
    static let emailFrom = "From"
    static let emailTo = "To"
    static let window = "Only during the box's reporting hours"
    static let windowHint = "08:00–23:00 by default. Alerts outside them wait and arrive as one summary."
    static let secretsNote = "The token and the password stay in this Mac's Keychain; the box gets them sealed to its own key, in a file only it can read."
    static let save = "Save and start"
    static let test = "Send test alert"
    static let turnOff = "Turn off"
    static let needSink = "Turn on ntfy or email and fill in its address."
    static let saved = "Saved. The box sends alerts from now on."
    static let off = "Alerts are off on this server."
    static let newerOnBox = "Another Mac saved newer alert settings on this server; they were kept."
    static let running = "Running"
    static let notRunning = "Not running"
    static let notSetUp = "Not set up on this server yet."
    static func lastSent(_ when: String) -> String { "Last alert sent \(when)" }
    static func lastError(_ text: String) -> String { "Last error: \(text)" }
    static func held(_ until: String) -> String { "SwarmHub is active here, so the box holds alerts back until \(until) unless it hears from SwarmHub again." }
    static func testResult(_ sinks: [String: String]) -> String {
        "Test alert: " + sinks.sorted { $0.key < $1.key }.map { "\($0.key == "email" ? email : ntfy) \($0.value)" }.joined(separator: " · ")
    }
    static func serviceError(_ reason: String) -> String { "Saved, but the alert service could not be started: \(reason)" }
    static func refused(_ reason: String) -> String { "The box refused: \(reason)" }
    static let unreadable = "The box gave no readable answer. Is the Swarm Hub messages skill (1.4.12 or later) installed on this server?"
    static let noRunner = "No agent on this server can run the command."
    static let noBoxKey = "The box's key is not known yet. Refresh the status first."
    static let sealFailed = "The settings could not be sealed for the box."
    static func exited(_ code: Int) -> String { "the alerts command exited with status \(code)" }
    static let turnRequest = "Run the alerts command."
    static let nativeSessions = "Alerts need native Hermes sessions on this box."
    static let skillMissing = "The Swarm Hub messages skill is not installed for this server's agent. Install it from the agent's settings."

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        [title, caption, presenceNote, noServers, load, loadCaption, refresh, working, ntfy, ntfyURL, ntfyPlaceholder, ntfyToken,
         email, emailHost, emailPort, emailSecurity, security(.starttls), security(.ssl), security(.none), emailUser,
         emailPassword, emailFrom, emailTo, window, windowHint, secretsNote, save, test, turnOff, needSink, saved, off, running,
         notRunning, notSetUp, lastSent("2 min ago"), lastError("ntfy answered HTTP 403"), held("14:05"),
         testResult(["ntfy": "sent"]), serviceError("no service manager"), refused("bad"), unreadable, noRunner, noBoxKey,
         sealFailed, exited(1), turnRequest, nativeSessions, skillMissing]
    }
}

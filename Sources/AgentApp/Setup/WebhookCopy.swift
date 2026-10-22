import Foundation

/// Every visible string of the Routines tab's Webhooks section and its sheet. Plain words, "agent", never "bot".
enum WebhookCopy {
    static let title = "Webhooks"
    static let header = "X-SwarmHub-Key"
    static let refresh = "Refresh webhooks"
    static let newWebhook = "New webhook"
    static let load = "Show webhooks"
    static let loadCaption = "Reading this agent's webhooks runs one short command on its box."
    static let working = "Working…"
    static let empty = "No webhooks yet. Create one to wake this agent from another service."
    static func receiverRunning(_ listen: String) -> String { "Receiver running on \(listen)" }
    static let receiverDown = "Receiver not running"
    static let startReceiver = "Start receiver"
    static func receiverRefused(_ reason: String) -> String { "The receiver could not be started: \(reason)" }
    static let loopbackNote = "These addresses answer only on the box itself. To call them from elsewhere, the box owner puts a reverse proxy in front of the receiver and sets webhook_base."
    static func calls(_ count: Int) -> String { count == 1 ? "Called once" : "Called \(count) times" }
    static func keyChanged(_ when: String) -> String { "key changed \(when)" }
    static let copyAddress = "Copy address"
    static let copyKey = "Copy key"
    static let copyExample = "Copy example command"
    static let rotate = "New key"
    static let rotateConfirm = "Replace the key? Callers using the old one stop working at once."
    static let delete = "Delete"
    static let deleteConfirm = "Delete this webhook? Its address stops working at once."
    static let cancel = "Cancel"
    static let name = "Name"
    static let namePlaceholder = "nightly-report"
    static let nameHint = "Letters, digits, dots, dashes or underscores; up to 64. It names the webhook in the wake message."
    static let create = "Create"
    static let created = "Webhook created"
    static let rotated = "New key"
    static let address = "Address"
    static let key = "Key"
    static let headerLine = "Send the key in the \(header) header and JSON {\"text\": \"…\"} as the body."
    static let onceWarning = "This key is shown once. Swarm Hub keeps no copy; if you lose it, make a new key."
    static let done = "Done"
    static let invalidName = "Use a name of letters, digits, dots, dashes or underscores (up to 64)."
    static let skillMissing = "The Swarm Hub messages skill is not installed for this agent. Install it from the agent's settings."
    static let boxUnavailable = "The box connection is unavailable."
    static let cleanupPending = "Temporary session cleanup is pending; retry when the box is reachable."
    static let nativeSessions = "Webhook management needs native Hermes sessions on this box."
    static let turnRequest = "Run the webhook command."

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] {
        [title, header, refresh, newWebhook, load, loadCaption, working, empty, receiverRunning("127.0.0.1:8745"), receiverDown,
         startReceiver, receiverRefused("no service manager"), loopbackNote, calls(1), calls(3), keyChanged("2 h ago"), copyAddress,
         copyKey, copyExample, rotate, rotateConfirm, delete, deleteConfirm, cancel, name, namePlaceholder, nameHint, create,
         created, rotated, address, key, headerLine, onceWarning, done, invalidName, skillMissing, boxUnavailable,
         cleanupPending, nativeSessions, turnRequest]
    }
}

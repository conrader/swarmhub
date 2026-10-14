import Foundation

/// P35's words: the setup window's "Found N bots" step, the confirmation sheet, the sidebar's "not connected" section,
/// Settings → "Add all bots from this box" and the manager's notices. The brief's own lines say "bots" (accepted by
/// Konrad), so they are kept apart from `SetupCopy`, whose D12 rule says "agents". None ever contains a key.
enum BoxCopy {
    // Setup window, "Found N bots on this box"
    static func found(_ count: Int) -> String { count == 1 ? "Found 1 bot on this box" : "Found \(count) bots on this box" }
    static let looking = "Looking for every bot on this box…"
    static let lookFailed = "Couldn’t list the other bots on this box now. Add them later: Settings → Advanced → Servers and keys → Add all bots from this box."
    static func managerLine(_ name: String) -> String { "\(name) will set up the other bots on this box." }
    static func adopting(manager: String, count: Int) -> String {
        "\(manager) is connecting \(count == 1 ? "1 more bot" : "\(count) more bots") in its chat; they appear in the sidebar as they answer."
    }
    static func adoptHeader(_ count: Int) -> String { count == 1 ? "Connect 1 more bot" : "Connect \(count) more bots" }
    static let adoptToggle = "Connect these too"
    /// S4's Add when the batch is on: the ticked agents plus the bots to connect.
    static func addButton(_ count: Int) -> String { count == 1 ? "Add 1 bot" : "Add \(count) bots" }
    /// The box's main bot (`default`) in lists: its profile has no name of its own.
    static let mainBot = "Main bot"
    static let adoptDetail = "For each of these, the bot that sets up the others backs up its key file on the box, then gives it its own key. Anything else that used its old key needs the new one; you can restore the old key per bot in its settings."
    static let needsKeyHeader = "Needs its own key"
    /// D4's one line.
    static let mainBotWhy = "The box’s main bot: its key is never changed, because the box’s own web chat uses it. Paste its key once to add it."
    static let typedWhy = "You typed this bot’s key, so it is never changed."

    // Confirmation sheet
    static func sheetTitle(_ count: Int) -> String { count == 1 ? "Connect 1 bot from this box?" : "Connect \(count) bots from this box?" }
    static func sheetDetail(manager: String) -> String {
        "\(manager) backs up each bot’s key file on the box (.env.swarmhub-bak-…), then gives the bot its own \(AppConstants.name) key. Anything else that used a bot’s old key needs the new one. Undo per bot: “Restore this bot’s old key” in its settings."
    }
    static func connectButton(_ count: Int) -> String { count == 1 ? "Connect 1 bot" : "Connect \(count) bots" }
    static let busy = "Another reply is still running. Try again when it has finished."

    // Sidebar
    static func sectionTitle(place: String?) -> String { place.map { "On \($0) · not connected" } ?? "On this box · not connected" }
    static let connect = "Connect"
    static let connectAutomatically = "Connect automatically…"
    static let pasteKey = "Paste its key…"
    static func rowLine(_ state: BoxProfile.State) -> String {
        switch state {
        case .adoptable: "Not connected"
        case .adopting: "Connecting…"
        case .failed: "Couldn’t connect"
        case .needsKey: "Key needed"
        }
    }

    // Settings and notices
    static let addAllButton = "Add all bots from this box"
    static let addAllCaption = "Lists every bot on your box: bots that already answer are added at once; the others are listed for you to connect."
    static let noBox = "No box is connected yet."
    static let noManager = "No bot on this box can list the others (none has a key on this Mac)."
    static func couldNotList(_ manager: String) -> String { "\(manager) couldn’t list the bots on this box now." }
    static func scanned(_ scan: BoxScan) -> String {
        var parts = ["Found \(scan.listed == 1 ? "1 bot" : "\(scan.listed) bots")"]
        if !scan.added.isEmpty { parts.append("added \(names(scan.added))") }
        if !scan.adoptable.isEmpty { parts.append("\(scan.adoptable.count) to connect") }
        if !scan.needsKey.isEmpty { parts.append("\(scan.needsKey.count) need their own key") }
        return parts.joined(separator: "; ") + "."
    }
    static let mainBotKey = "The box’s main bot needs its own key (it is never changed): paste it under Add bots from box."
    static func adopted(added: [String], failed: [String]) -> String {
        var lines: [String] = []
        if !added.isEmpty { lines.append("Connected \(names(added)).") }
        if !failed.isEmpty { lines.append("Couldn’t connect \(names(failed)); they are listed under “not connected”.") }
        return lines.isEmpty ? "Nothing was connected." : lines.joined(separator: " ")
    }
    static func restored(_ name: String) -> String { "\(name)’s old key is back on the box; \(name) is no longer connected here." }
    static func restoreFailed(_ name: String) -> String { "Couldn’t restore \(name)’s old key; nothing changed here." }
    static let restoreButton = "Restore this bot’s old key"
    static var restoreCaption: String { "\(AppConstants.name) connected this bot by giving it a new key (its old key file was backed up on the box). Restoring puts the old key back and disconnects it here." }

    static func names(_ profiles: [String]) -> String { profiles.map(HermesProfileNaming.botName(forProfile:)).joined(separator: ", ") }
}

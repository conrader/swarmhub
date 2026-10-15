import Foundation

/// P35: a profile on a box that SwarmHub has no bot for after discovery, and what is next for it (the sidebar's
/// "On this box · not connected" and the wizard's list).
struct BoxProfile: Identifiable, Equatable {
    enum State: Equatable {
        /// SwarmHub can connect it: the manager backs up its key file and gives it its derived key.
        case adoptable
        case adopting
        /// Connecting it failed (the manager said so, or it did not answer with the new key).
        case failed
        /// The box's main bot (`default`) or a bot whose key Konrad typed: never re-keyed, only its own key connects it.
        case needsKey
    }
    var id: String { name }
    let name: String
    var hasKey: Bool
    var state: State
    var botName: String { name == "default" ? BoxCopy.mainBot : HermesProfileNaming.botName(forProfile: name) }
}

/// A batch the confirmation sheet asks about: the manager that will run it and the profiles.
struct AdoptionOffer: Identifiable, Equatable {
    let id = UUID()
    let managerID: UUID; let managerName: String; let names: [String]
}

/// The P35 recipes (`Resources/BotManager/recipes/box.md`: "List every bot", "Connect bots", "Restore a connected
/// bot's old key"), filled per turn, and the rules for which profiles may be re-keyed. Each recipe prints the one JSON
/// line the manager returns in its swarmhub block; no recipe prints a key.
enum BoxAdoption {
    static let listMarker = "List every bot:"
    static let adoptMarker = "Connect bots ("
    static let restoreMarker = "Restore a connected bot's old key:"
    static let closeReportsMarker = "Close reports ("

    /// The fenced block after the first line containing `marker`; nil when absent.
    static func recipe(_ marker: String, in template: String) -> String? {
        let lines = template.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) }),
              let open = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("```") }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("```") }) else { return nil }
        return lines[(open + 1)..<close].joined(separator: "\n")
    }

    /// The names SwarmHub may ask the manager to re-key: valid profile names, never `default`, never the manager
    /// itself, never a profile whose key Konrad typed, never one already bound to a bot. Order kept, duplicates dropped.
    static func adoptable(_ names: [String], managerProfile: String, typed: Set<String>, bound: Set<String>) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            HermesKeyPaste.isValidProfileName(name) && name != "default" && name != managerProfile && !typed.contains(name)
                && !bound.contains(name) && seen.insert(name).inserted
        }
    }

    /// Discovery's list sorted out: profiles already bound and the manager drop out; `default` and typed-key profiles
    /// need their own key; the rest are tried with their derived key first.
    static func sort(_ listed: [SwarmhubOp.ListedBot], managerProfile: String, typed: Set<String>, bound: Set<String>)
        -> (candidates: [SwarmhubOp.ListedBot], needsKey: [SwarmhubOp.ListedBot]) {
        let open = listed.filter { $0.name != managerProfile && !bound.contains($0.name) }
        let needsKey = open.filter { $0.name == "default" || typed.contains($0.name) }
        return (open.filter { row in !needsKey.contains { $0.name == row.name } }, needsKey)
    }

    static func listInstructions(template: String, managerProfile: String) -> String? {
        guard let recipe = recipe(listMarker, in: template) else { return nil }
        return turn("SwarmHub is checking which bots are on this box. Reading needs no confirmation.",
                    BotManagerText.filled(recipe, managerProfile: managerProfile))
    }

    static func adoptInstructions(template: String, managerProfile: String, names: [String]) -> String? {
        guard !names.isEmpty, names.allSatisfy(HermesKeyPaste.isValidProfileName), let recipe = recipe(adoptMarker, in: template) else { return nil }
        let filled = BotManagerText.filled(recipe, managerProfile: managerProfile).replacingOccurrences(of: "<names>", with: names.joined(separator: " "))
        return turn("Konrad pressed Connect in SwarmHub for these bots: \(names.joined(separator: ", ")). That press is his yes: do not ask again.", filled)
    }

    static func restoreInstructions(template: String, managerProfile: String, name: String, backup: String) -> String? {
        guard HermesKeyPaste.isValidProfileName(name), backup.isEmpty || SwarmhubOp.AdoptionResult.isValidBackup(backup),
              let recipe = recipe(restoreMarker, in: template) else { return nil }
        let filled = BotManagerText.filled(recipe, managerProfile: managerProfile)
            .replacingOccurrences(of: "<name>", with: name).replacingOccurrences(of: "<backup>", with: backup)
        return turn("Konrad pressed “Restore this bot’s old key” in SwarmHub for \(name). That press is his yes: do not ask again.", filled)
    }

    /// P36: rename the sent reports' files to `.sent`, delete the dismissed ones (ids checked here and in the recipe).
    static func closeReportsInstructions(template: String, managerProfile: String, sent: [String], deleted: [String]) -> String? {
        guard !(sent + deleted).isEmpty, (sent + deleted).allSatisfy(SwarmReport.isValidLocalID), let recipe = recipe(closeReportsMarker, in: template) else { return nil }
        let filled = BotManagerText.filled(recipe, managerProfile: managerProfile)
            .replacingOccurrences(of: "<sent>", with: sent.joined(separator: " ")).replacingOccurrences(of: "<deleted>", with: deleted.joined(separator: " "))
        return turn("Konrad sent or dismissed these SwarmHub reports in SwarmHub; their files on this box are done with. Reading and renaming them needs no confirmation.", filled)
    }

    private static func turn(_ lead: String, _ command: String) -> String {
        """
        \(lead) Run exactly this command in your terminal with the shell (not the file tool), change nothing else, then reply \
        in one short line and end with a swarmhub block holding exactly the JSON line it printed. Never show a key.
        ````sh
        \(command)
        ````
        """
    }
}

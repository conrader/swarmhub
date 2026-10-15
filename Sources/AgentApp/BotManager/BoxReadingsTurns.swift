import Foundation

/// P31 D: a sub-agent model change SwarmHub asks the manager for: the P30 model recipe with
/// `KM=delegation.model KP=delegation.provider`. An empty model and provider clear the pin (each bot's own model).
struct SubAgentModelChange: Equatable {
    enum Bots: Equatable { case some([String]), all }
    var model: String
    var provider: String
    var bots: Bots

    static func clear(_ bots: Bots) -> SubAgentModelChange { SubAgentModelChange(model: "", provider: "", bots: bots) }

    var clears: Bool { model.isEmpty && provider.isEmpty }

    /// Ids of the allowed characters, both set or both empty, and at least one valid profile name.
    var isValid: Bool {
        guard BotModels.isValidID(model), BotModels.isValidID(provider), model.isEmpty == provider.isEmpty else { return false }
        if case .some(let names) = bots { return !names.isEmpty && names.allSatisfy(HermesKeyPaste.isValidProfileName) }
        return true
    }

    /// The recipe's `<names>`: the profiles, or every bot on the box.
    var names: String {
        switch bots {
        case .some(let names): names.joined(separator: " ")
        case .all: "default $(ls ~/.hermes/profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')"
        }
    }

    /// "jarvis, mira" or "all bots".
    var who: String { if case .some(let names) = bots { names.joined(separator: ", ") } else { "all bots" } }

    /// The line Konrad sees in the manager's chat.
    var request: String {
        clears ? "Clear the sub-agent model of \(who): their sub-agents use each bot's own model."
            : "Change the sub-agent model of \(who) to \(model) (\(provider))."
    }
}

/// The opened sheet: the manager that will be asked and the bot it was opened from (nil: Manage bots).
struct SubAgentModelRequest: Identifiable, Equatable {
    let id = UUID()
    let managerID: UUID
    var profile: String?
}

/// A quiet check running on a connection (`connection(of:)`).
enum BoxCheck: Hashable { case models(String), capacity(String) }

/// The P31 D+E manager turns: the quiet reads ("Bot models", "Box capacity") and the two asks Konrad confirms in the
/// manager's chat (a sub-agent model change, the coding job limit), each carrying only its recipe.
enum BoxReadingsTurns {
    static let modelsMarker = "Bot models ("
    static let capacityMarker = "Box capacity ("
    static let limitMarker = "Set the coding job limit"
    static let changeModelMarker = "Change the model (one bot"

    static func modelsInstructions(template: String) -> String? {
        BoxAdoption.recipe(modelsMarker, in: template).map {
            quiet("SwarmHub is reading each bot's model and sub-agent model on this box. Reading needs no confirmation.", [("", $0)])
        }
    }

    static func capacityInstructions(template: String) -> String? {
        BoxAdoption.recipe(capacityMarker, in: template).map {
            quiet("SwarmHub is reading this box's capacity for coding jobs. Reading needs no confirmation.", [("", $0)])
        }
    }

    /// Konrad pressed "Use advised" or "Set limit…": the manager asks him, then writes `SLOTS` and reports the capacity.
    static func limitInstructions(_ slots: Int, template: String) -> String? {
        guard (1...1024).contains(slots), let limit = BoxAdoption.recipe(limitMarker, in: template),
              let probe = BoxAdoption.recipe(capacityMarker, in: template) else { return nil }
        let steps = [("", limit.replacingOccurrences(of: "<slots>", with: String(slots))), ("Then:", probe)]
        return asked("""
            Konrad asked in SwarmHub to let this box run \(slots) coding \(slots == 1 ? "job" : "jobs") at a time (`SLOTS=\(slots)` in \
            ~/.hermes/swarmhub/coding.conf; running jobs keep going, the next job uses it). Ask him first in one short message and \
            wait for his yes. Then run exactly these commands in your terminal with the shell (not the file tool), change nothing \
            else, and end your reply with a swarmhub block holding exactly the JSON line the last one printed.
            """, steps)
    }

    /// The model recipe of the core (`core`) for sub-agents, filled; the manager asks first and reports per bot.
    static func subAgentInstructions(_ change: SubAgentModelChange, core: String) -> String? {
        guard change.isValid, let recipe = BoxAdoption.recipe(changeModelMarker, in: core) else { return nil }
        var lines = recipe.components(separatedBy: "\n")
        guard let export = lines.firstIndex(where: { $0.hasPrefix("export MODEL=") }) else { return nil }
        lines[export] = "export MODEL=\(change.model) PROV=\(change.provider) KM=delegation.model KP=delegation.provider"
        let filled = lines.joined(separator: "\n").replacingOccurrences(of: "<names>", with: change.names)
        let what = change.clears ? "clear the sub-agent model (so sub-agents use each bot's own model)"
            : "set the sub-agent model to \(change.model), provider \(change.provider)"
        return asked("""
            Konrad asked in SwarmHub to \(what) for \(change.who). Ask him first in one \
            short message naming model, provider and bots, and wait for his yes. Then start this as a background process of your \
            terminal tool (its background option, not nohup/setsid), wait for it, `cat ~/.hermes/swarmhub-model.log` (ends with DONE) \
            and report ok/FAILED per bot; for FAILED show the last lines of ~/.hermes/swarmhub-model.err. Change nothing else.
            """, [("", filled)])
    }

    private static func body(_ steps: [(String, String)]) -> String {
        steps.map { ($0.0.isEmpty ? "" : $0.0 + "\n") + "````sh\n\($0.1)\n````" }.joined(separator: "\n")
    }

    private static func quiet(_ lead: String, _ steps: [(String, String)]) -> String {
        """
        \(lead) Run exactly this in your terminal with the shell (not the file tool), change nothing else, then reply in one \
        short line and end with a swarmhub block holding exactly the JSON line it printed.
        \(body(steps))
        """
    }

    private static func asked(_ lead: String, _ steps: [(String, String)]) -> String { lead + "\n" + body(steps) }
}

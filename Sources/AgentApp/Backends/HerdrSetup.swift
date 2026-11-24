import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The name people use for an agent program. The server says it (`display_name` on a template's runtime, such as
/// "Claude"). A server that does not send one still gets a short name: the program's own name without the last word
/// when that word only says what kind of program it is ("Claude Code" reads "Claude"). The app keeps no table of
/// programs; these few words name no product.
enum HerdrProgramName {
    static let kinds: Set<String> = ["code", "cli", "agent", "assistant", "app"]

    static func friendly(display: String?, program: String?) -> String? {
        if let display = display?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty { return baseName(display) }
        guard let program = program?.trimmingCharacters(in: .whitespacesAndNewlines), !program.isEmpty else { return nil }
        var words = baseName(program).split(separator: " ")
        while words.count > 1, let last = words.last, kinds.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func baseName(_ name: String) -> String {
        let base = name.replacingOccurrences(of: #"(?:\s*\([^()]*\))+$"#, with: "", options: .regularExpression)
        return base.isEmpty ? name : base
    }

    /// The name of a bot that is named after its program: the program's name without the server's "(beta)", so
    /// a bot on "Gemini (beta)" is called "Gemini" and keeps that name when the program is no longer in beta.
    static func botName(_ program: String) -> String {
        let mark = " (beta)"
        guard program.count > mark.count, program.lowercased().hasSuffix(mark) else { return program }
        return String(program.dropLast(mark.count))
    }

    /// One label per template, in order: its friendly name, with the template's own name added only where two of
    /// them would otherwise read the same.
    static func labels(for templates: [HerdrClient.Template]) -> [String: String] {
        let byLabel = Dictionary(grouping: templates) { $0.label.lowercased() }
        var labels: [String: String] = [:]
        for group in byLabel.values {
            let ambiguous = Set(group.map(\.name)).count > 1
            for template in group {
                let label = template.label
                labels[template.name] = ambiguous && label != template.name ? "\(label) · \(template.name)" : label
            }
        }
        return labels
    }
}

/// The labels of the models the servers have listed since the app started, by id. A helper is reported with its
/// model's id alone by a server that does not send the label (`model_label`); it then reads by the label the app
/// already saw for that id, and by the id only when it never saw one.
enum HerdrModelNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var labels: [String: String] = [:]

    static func remember(_ models: [HerdrClient.Template.Model]) {
        lock.withLock { for model in models { if let label = model.label, !label.isEmpty { labels[model.id] = label } } }
    }

    static func label(_ id: String?) -> String? { id.flatMap { id in lock.withLock { labels[id] } } }
}

/// One agent program a server can start, as the setup wizard offers it: the server's template, the program's own
/// name and the models the server lists for it. Every name here is the server's; the app names no program and no model.
struct HerdrProgram: Equatable, Identifiable, Sendable {
    let template: String
    /// The agent program as the server calls it; a template that names none goes by its own name.
    let name: String
    /// False: the program picks its own model and the server offers no choice.
    let takesModel: Bool
    let models: [HerdrClient.Template.Model]
    var modelAgent: String? = nil
    /// The server says the program is in beta, and in `note` what it cannot do yet (`HerdrClient.Template`).
    var beta = false
    var note: String? = nil
    var id: String { template }

    /// The model a bot on this program starts on unless its person chooses another: the first the server offers.
    var defaultModel: HerdrClient.Template.Model? { HerdrClient.defaultModel(offered: models).flatMap { id in models.first { $0.id == id } } }
    static func modelName(_ model: HerdrClient.Template.Model) -> String { model.label ?? model.id }
}

/// Stored in app settings only. Resolve against the selected agent's catalog on every fresh launch.
enum HerdrModelChoice {
    static let recommended = "@recommended"

    static func apiModelID(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let syntax = #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.:/@+#\[\]-]*$"#
        guard id.utf8.count <= 160, id.range(of: syntax, options: .regularExpression) != nil else { return nil }
        return id
    }

    static func suggested(program: String?, offered: [HerdrClient.Template.Model]) -> HerdrClient.Template.Model? {
        let families: [String]
        switch HerdrProgramName.friendly(display: nil, program: program)?.lowercased() {
        case "codex": families = ["sol", "terra"]
        case "claude": families = ["sonnet"]
        case "opencode": return nil // OpenCode's configured provider and default model.
        default: families = []
        }
        for family in families {
            if let match = offered.first(where: { model in
                (model.id + " " + (model.label ?? "")).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(family))
            }) { return match }
        }
        return offered.first
    }
}

extension HerdrProgram {
    var starterName: String { HerdrProgramName.friendly(display: nil, program: modelAgent ?? name)?.lowercased() ?? "" }
}

/// What a server offers the setup wizard: its agent programs with their models, and the agents running there now.
/// Foundation only, like the rest of the Herdr client.
struct HerdrOffer: Equatable, Sendable {
    var programs: [HerdrProgram] = []
    /// The names of the agents running on the server now (a bot's own agent, never a helper).
    var running: [String] = []
    /// The server's workspace can add project servers (`HerdrProjects.swift`); an older one cannot, and the wizard
    /// then has no step for them.
    var projectServers = false
    var workspaceRoot: String? = nil

    func program(_ template: String) -> HerdrProgram? { programs.first { $0.template == template } }

    /// The programs with those in beta last, each group in the server's order. "The first program" is the default
    /// in several places, so a beta program is the default only when the server offers no other.
    static func betaLast(_ programs: [HerdrProgram]) -> [HerdrProgram] {
        programs.filter { !$0.beta } + programs.filter { $0.beta }
    }

    /// The program's name, with its template while two of the server's programs share that name.
    func label(_ program: HerdrProgram) -> String {
        programs.filter { $0.name == program.name }.count > 1 ? "\(program.name) · \(program.template)" : program.name
    }

    /// The programs' names as a sentence part: "A", "A and B", "A, B and C".
    var names: String {
        var seen: [String] = []
        for program in programs where !seen.contains(program.name) { seen.append(program.name) }
        guard seen.count > 1 else { return seen.first ?? "" }
        return seen.dropLast().joined(separator: ", ") + " and " + seen[seen.count - 1]
    }

    /// Whether a message to the bot whose agent has this name starts a new agent: none with that name, or with the
    /// same id suffix after a rename, runs now (`HerdrClient.liveAgent`).
    func startsAgent(named agentName: String) -> Bool {
        !running.contains { $0 == agentName || HerdrClient.suffix(of: $0) == HerdrClient.suffix(of: agentName) }
    }

    /// One program per other agent program the server offers, for the wizard's optional bots: not the main bot's
    /// program, not one whose template a bot on the server already uses (`taken`), and not one whose name a bot there
    /// already has (`names`, lowercased). Two templates of the same program count once, the first.
    func others(than template: String?, taken: Set<String>, names: Set<String>) -> [HerdrProgram] {
        let main = template.flatMap(program)?.name
        var found: [HerdrProgram] = []
        for program in programs where program.name != main && !found.contains(where: { $0.name == program.name }) {
            let covered = programs.contains { $0.name == program.name && taken.contains($0.template) }
            if !covered, !names.contains(HerdrProgramName.botName(program.name).lowercased()) { found.append(program) }
        }
        return found
    }
}

/// Why a server cannot be used yet, in the four ways the setup wizard tells apart, each with its own plain line:
/// it cannot be reached, it does not accept the access key, it answers without Herdr Core, or Core has no agent
/// program to start. Anything else keeps the sentence the error came with.
enum HerdrSetupProblem: Error, Equatable, Sendable {
    /// Nothing answers at the address (a typed address, or a forward that is not open).
    case unreachable
    /// ssh could not log in or connect; `line` is ssh's own last line.
    case sshFailed(String)
    /// ssh logged in, but the bridge's access key file is not there: the SwarmHub service was never started.
    case sshNoService
    /// ssh logged in, but nothing answers on the server's port.
    case sshNoAnswer
    case noKey, wrongKey, refusedHost
    /// The bridge answers; Herdr Core beside it does not.
    case noCore
    /// Core runs, but has no template it can start an agent from.
    case noPrograms
    case other(String)

    /// What an error of the Herdr client, of the tunnel or of the network means for the wizard. `readingKey`: the
    /// error came from reading the access key file over ssh, before any request to the bridge.
    static func of(_ error: Error, readingKey: Bool = false) -> HerdrSetupProblem {
        if let known = error as? HerdrSetupProblem { return known }
        if let failure = error as? HerdrClient.Failure {
            switch failure {
            case .unauthorized: return .wrongKey
            case .refusedHost: return .refusedHost
            case .http(503, _): return .noCore
            default: return .other(failure.localizedDescription)
            }
        }
        if let tunnel = error as? HerdrTunnel.Failure {
            switch tunnel {
            case .timedOut: return .sshNoAnswer
            case .ended(let line): return readingKey && line.localizedCaseInsensitiveContains("No such file") ? .sshNoService : .sshFailed(line)
            case .notSSH: return .other(tunnel.localizedDescription)
            }
        }
        if case BackendError.unavailable(let line) = error { return line == HerdrBackend.missingToken ? .noKey : .other(line) }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return .unreachable }
        return .other(error.localizedDescription)
    }

    /// One or two plain sentences for `server`. They say "access key", the setup window's word for the bridge's token.
    func line(for server: HerdrServer) -> String {
        switch self {
        case .unreachable:
            switch server.kind {
            case .local: return "Nothing answers on this Mac at 127.0.0.1:\(server.port)."
            case .ssh: return "\(server.sshHost) was reached over SSH, but nothing answers on its port \(server.port). Start Herdr Core and the \(AppConstants.name) service there, then press Try again."
            case .address: return "The server is not reachable: nothing answers at \(server.address). Check the address. A server on another computer needs its port forwarded to this Mac first, or go back and choose SSH."
            }
        case .sshFailed(let line):
            let said = " (ssh said: \(line))"
            if line.localizedCaseInsensitiveContains("Permission denied") { return "\(server.sshHost) refused the login. Check the username. If this account requires an SSH key, choose one in Connection details." + said }
            if line.localizedCaseInsensitiveContains("Could not resolve hostname") { return "No server named \(server.sshHost) was found. Check the name." }
            if ["Connection refused", "timed out", "No route to host", "Network is unreachable"].contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                return "\(server.sshHost) is not reachable over SSH. Check that the server is on and that this Mac is online." + said
            }
            return "The SSH connection to \(server.sshHost) did not open." + said
        case .sshNoService:
            return "\(server.sshHost) was reached over SSH, but the \(AppConstants.name) service has never been started there: its access key file is missing. Start Herdr Core and the \(AppConstants.name) service on the server, then press Try again."
        case .sshNoAnswer:
            return "\(server.sshHost) was reached over SSH, but nothing answers on its port \(server.port). Start Herdr Core and the \(AppConstants.name) service there, then press Try again."
        case .noKey:
            return server.kind == .address ? "Paste the server's access key, then press Try again."
                : "The server answers, but its access key was not found. Paste the access key, then press Try again."
        case .wrongKey: return "The server answered, but did not accept the access key. Check the key, then press Try again."
        case .refusedHost: return HerdrClient.Failure.refusedHost.localizedDescription
        case .noCore: return "The server answered, but Herdr Core is not running on it. Start Herdr Core there, then press Try again."
        case .noPrograms:
            return "Connected, but no AI is set up on this server yet. Add one there (an agent program and its Herdr template), then press Try again."
        case .other(let line): return line
        }
    }
}

extension HerdrClient {
    /// Reads what the server offers the wizard. Throws `HerdrSetupProblem.noCore` when the bridge answers without
    /// Core; a server with no usable template returns an offer with no programs. A program whose models cannot be
    /// listed right now is offered with the ones the template names.
    func offer() async throws -> HerdrOffer {
        let current = try await workspace()
        guard current.core != nil else { throw HerdrSetupProblem.noCore }
        var programs: [HerdrProgram] = []
        for template in current.templates where template.error == nil {
            let models = template.takesModel ? ((try? await models(for: template)) ?? template.models ?? []) : []
            programs.append(HerdrProgram(template: template.name, name: template.label, takesModel: template.takesModel, models: models, modelAgent: template.modelAgent,
                                         beta: template.beta ?? false, note: template.note))
        }
        programs = HerdrOffer.betaLast(programs)
        // Asked once here, so the wizard knows whether to offer the step; a workspace without the route answers 404.
        let projectServers = (try? await machines()) != nil
        return HerdrOffer(programs: programs, running: current.agents.filter { $0.isLive && $0.parent == nil }.map(\.name), projectServers: projectServers, workspaceRoot: current.workspaceRoot)
    }
}

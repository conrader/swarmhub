import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One agent program a server can start, as the setup wizard offers it: the server's template, the program's own
/// name and the models the server lists for it. Every name here is the server's; the app names no program and no model.
struct HerdrProgram: Equatable, Identifiable, Sendable {
    let template: String
    /// The agent program as the server calls it; a template that names none goes by its own name.
    let name: String
    /// False: the program picks its own model and the server offers no choice.
    let takesModel: Bool
    let models: [HerdrClient.Template.Model]
    var id: String { template }

    /// The model a bot on this program starts on unless its person chooses another: the first the server offers.
    var defaultModel: HerdrClient.Template.Model? { HerdrClient.defaultModel(offered: models).flatMap { id in models.first { $0.id == id } } }
    static func modelName(_ model: HerdrClient.Template.Model) -> String { model.label ?? model.id }
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

    func program(_ template: String) -> HerdrProgram? { programs.first { $0.template == template } }

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
            if !covered, !names.contains(program.name.lowercased()) { found.append(program) }
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
            case .ssh: return "\(server.sshHost) was reached over SSH, but nothing answers on its port \(server.port). Start Herdr Core and the \(AppConstants.name) service there, then press Test again."
            case .address: return "The server is not reachable: nothing answers at \(server.address). Check the address. A server on another computer needs its port forwarded to this Mac first, or go back and choose SSH."
            }
        case .sshFailed(let line):
            let said = " (ssh said: \(line))"
            if line.localizedCaseInsensitiveContains("Permission denied") { return "\(server.sshHost) refused the login. Check the login name and the SSH key file; a key with a passphrase must be unlocked first." + said }
            if line.localizedCaseInsensitiveContains("Could not resolve hostname") { return "No server named \(server.sshHost) was found. Check the name." }
            if ["Connection refused", "timed out", "No route to host", "Network is unreachable"].contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                return "\(server.sshHost) is not reachable over SSH. Check that the server is on and that this Mac is online." + said
            }
            return "The SSH connection to \(server.sshHost) did not open." + said
        case .sshNoService:
            return "\(server.sshHost) was reached over SSH, but the \(AppConstants.name) service has never been started there: its access key file is missing. Start Herdr Core and the \(AppConstants.name) service on the server, then press Test again."
        case .sshNoAnswer:
            return "\(server.sshHost) was reached over SSH, but nothing answers on its port \(server.port). Start Herdr Core and the \(AppConstants.name) service there, then press Test again."
        case .noKey:
            return server.kind == .address ? "Paste the server's access key, then press Test again."
                : "The server answers, but its access key was not found. Paste the access key, then press Test again."
        case .wrongKey: return "The server answered, but did not accept the access key. Check the key, then press Test again."
        case .refusedHost: return HerdrClient.Failure.refusedHost.localizedDescription
        case .noCore: return "The server answered, but Herdr Core is not running on it. Start Herdr Core there, then press Test again."
        case .noPrograms:
            return "Connected, but no agent program is set up on this server: Herdr Core has no template it can start. Add an agent program and its Herdr template there, then press Test again."
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
            programs.append(HerdrProgram(template: template.name, name: template.runtime?.harness ?? template.name, takesModel: template.takesModel, models: models))
        }
        // Asked once here, so the wizard knows whether to offer the step; a workspace without the route answers 404.
        let projectServers = (try? await machines()) != nil
        return HerdrOffer(programs: programs, running: current.agents.filter { $0.isLive && $0.parent == nil }.map(\.name), projectServers: projectServers)
    }
}

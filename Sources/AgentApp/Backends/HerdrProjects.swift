import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Projects on other servers, as a Herdr server's workspace keeps them (`HerdrWorkspace/README.md`, "Work on projects on
// other servers"). A project server is a machine the Herdr server reaches over SSH with its own key; a project is a
// named folder on one; a bot may use the projects chosen for it, which lets its agent run commands and change files
// in those folders. The workspace does the connecting and keeps the lists: the app shows them and sends what the
// person decides. Foundation only, like the rest of the Herdr client.

/// One project server as the workspace lists it. `warnings` are the workspace's own sentences.
struct HerdrMachine: Decodable, Sendable, Equatable, Identifiable {
    let name: String
    /// How ssh reaches it, such as `deploy@10.0.0.7`.
    var target: String = ""
    /// What the machine calls itself.
    var host: String? = nil
    /// The version of Herdr's helper program there.
    var version: String? = nil
    /// `connecting`, `connected`, `needs_login`, `needs_update` or `unreachable`.
    var state: String = ""
    var reachable: Bool = false
    var why: String? = nil
    var warnings: [String] = []
    /// The names of the projects on it.
    var projects: [String] = []
    var id: String { name }

    enum CodingKeys: CodingKey { case name, target, host, version, state, reachable, why, warnings, projects }
    init(name: String, target: String = "", host: String? = nil, version: String? = nil, state: String = "connected", reachable: Bool = true, warnings: [String] = [], projects: [String] = []) {
        self.name = name; self.target = target; self.host = host; self.version = version; self.state = state; self.reachable = reachable; self.warnings = warnings; self.projects = projects
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""; host = try c.decodeIfPresent(String.self, forKey: .host)
        version = try c.decodeIfPresent(String.self, forKey: .version); state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        reachable = try c.decodeIfPresent(Bool.self, forKey: .reachable) ?? (state == "connected"); why = try c.decodeIfPresent(String.self, forKey: .why)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []; projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
    }

    /// The state in a word or two.
    var stateLine: String {
        switch state {
        case "connected": "Connected"
        case "connecting": "Connecting"
        case "needs_login": "Login refused"
        case "needs_update": "Needs an update"
        case "unreachable": "Not reachable"
        default: state.isEmpty ? "Unknown" : state
        }
    }
}

/// The project servers of one Herdr server (`GET /api/machines`).
struct HerdrMachines: Decodable, Sendable, Equatable {
    var machines: [HerdrMachine] = []
    var canAdd: Bool? = nil
    /// Why a server cannot be added from this workspace, in its words.
    var problem: String? = nil
    /// The workspace's sentence on what adding installs on the project server.
    var adding: String? = nil
    /// After a removal: the name that went.
    var removed: String? = nil
}

/// The Herdr server's own public keys (`GET /api/machines/ssh-key`): one is pasted on the project server.
struct HerdrSSHKeys: Decodable, Sendable, Equatable {
    struct Key: Decodable, Sendable, Equatable, Identifiable {
        /// The line to paste.
        let publicKey: String
        var type: String? = nil; var fingerprint: String? = nil; var comment: String? = nil; var file: String? = nil
        var id: String { publicKey }
    }
    var keys: [Key] = []
    /// The Herdr server has no key pair yet, and the workspace can make one.
    var canCreate: Bool? = nil
    var whereToPaste: String? = nil
    var problem: String? = nil
}

/// What adding a server answered with (`POST /api/machines`, 201).
struct HerdrMachineAdded: Decodable, Sendable, Equatable {
    let machine: HerdrMachine
    var helperInstalled: Bool? = nil
    /// The workspace's sentence: that the server was added, and what happened to Herdr's helper program there.
    var message: String? = nil
}

/// One project: a name, a server, a folder on it, and an optional note for the bots.
struct HerdrProject: Decodable, Sendable, Equatable, Identifiable {
    let id: Int
    var name: String
    var machine: String
    var folder: String
    var note: String = ""
    /// The server's state; `missing` when Herdr has no such machine any more, `unknown` when Core could not be asked.
    var machineState: String? = nil
    var reachable: Bool? = nil

    /// "shop (on box)", as the workspace itself names a project to an agent.
    var label: String { "\(name) (on \(machine))" }
}

/// A project as a bot's own list keeps it: the id the server knows it by, and the words to name it with.
struct HerdrBotProject: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    var name: String
    var machine: String
    var label: String { "\(name) (on \(machine))" }
    init(id: Int, name: String, machine: String) { self.id = id; self.name = name; self.machine = machine }
    init(_ project: HerdrProject) { id = project.id; name = project.name; machine = project.machine }
}

/// A running agent's projects (`GET` and `POST /api/agents/{address}/{created_ms}/projects`).
struct HerdrAgentProjects: Decodable, Sendable, Equatable {
    var projects: [HerdrProject] = []
    /// A helper: its list is the list of the agent that started it.
    var inherited: Bool? = nil
}

/// A request the workspace refused: its own sentence, to show as it is, and the word that says which case it is.
struct HerdrRefusal: LocalizedError, Equatable, Sendable {
    struct HostKey: Decodable, Sendable, Equatable, Identifiable {
        let type: String; let fingerprint: String
        var id: String { fingerprint }
    }
    let status: Int
    /// `unknown_host_key`, `login_refused`, `name_taken`, …; empty when the workspace gave none.
    let kind: String
    let message: String
    /// `unknown_host_key`: the host as ssh will know it, and the keys it shows.
    var host: String? = nil
    var hostKeys: [HostKey] = []

    var errorDescription: String? { message }

    private struct Body: Decodable { let error: String?; let kind: String?; let host: String?; let hostKeys: [HostKey]? }

    /// What a status other than 2xx means for these routes. A workspace that does not have them answers 404 with no
    /// sentence of its own: that is `older`.
    static func of(status: Int, body: Data) -> Error {
        if status == 401 { return HerdrClient.Failure.unauthorized }
        if status == 403 { return HerdrClient.Failure.refusedHost }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let said = try? decoder.decode(Body.self, from: body), let message = said.error, !message.isEmpty else {
            return HerdrRefusal(status: status, kind: status == 404 ? "older" : "", message: status == 404 ? HerdrProjectsCopy.olderWorkspace : "The Herdr workspace answered HTTP \(status).")
        }
        return HerdrRefusal(status: status, kind: said.kind ?? "", message: message, host: said.host, hostKeys: said.hostKeys ?? [])
    }
}

/// What adding a project server came to: it was added; the Herdr server has never seen this host and shows its keys
/// for the person to check; or the workspace refused, with its sentence.
enum HerdrMachineAddOutcome: Equatable, Sendable {
    case added(HerdrMachineAdded)
    case unknownHost(HerdrRefusal)
    case refused(String)
}

extension HerdrClient {
    /// Adding copies Herdr's helper program to the project server and can take a few minutes; the workspace stops it
    /// after 300 seconds and says so. The client waits a little longer, so that sentence arrives.
    static let machineAddSeconds: TimeInterval = 330, machineSeconds: TimeInterval = 60

    private func projectRoute<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = HerdrClient.machineSeconds) async throws -> T {
        let (data, status) = try await raw(request(path, method: method, body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, timeout: timeout))
        guard (200..<300).contains(status) else { throw HerdrRefusal.of(status: status, body: data) }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    func machines() async throws -> HerdrMachines { try await projectRoute("/api/machines") }

    /// The Herdr server's public keys; with `target` the ones ssh would use for that server.
    func sshKeys(target: String? = nil) async throws -> HerdrSSHKeys {
        let query = target.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }.map { "?target=\($0)" } ?? ""
        return try await projectRoute("/api/machines/ssh-key\(query)")
    }

    /// Makes the Herdr server's key pair when it has none (`canCreate`). It never replaces one.
    func createSSHKey() async throws -> HerdrSSHKeys { try await projectRoute("/api/machines/ssh-key", method: "POST", body: [:]) }

    /// Adds a project server by the address ssh takes. `accepting` is a fingerprint the workspace offered for a host
    /// it had not seen: only then does the Herdr server trust that key. Nothing here ever accepts one on its own.
    func addMachine(target: String, name: String?, accepting fingerprint: String? = nil) async -> HerdrMachineAddOutcome {
        var body: [String: Any] = ["target": target]
        if let name, !name.isEmpty { body["name"] = name }
        if let fingerprint, !fingerprint.isEmpty { body["accept_host_key"] = fingerprint }
        do { return .added(try await projectRoute("/api/machines", method: "POST", body: body, timeout: Self.machineAddSeconds)) }
        catch let refusal as HerdrRefusal where refusal.kind == "unknown_host_key" { return .unknownHost(refusal) }
        catch { return .refused(HerdrProjectsCopy.reason(error)) }
    }

    /// Makes Herdr forget a project server. A server that still has projects is refused.
    func removeMachine(_ name: String) async throws -> HerdrMachines { try await projectRoute("/api/machines/remove", method: "POST", body: ["name": name]) }

    /// Has Herdr try the server now, for after its key was pasted there.
    func connectMachine(_ name: String) async throws -> HerdrMachine {
        struct Answer: Decodable { let machine: HerdrMachine }
        let answer: Answer = try await projectRoute("/api/machines/connect", method: "POST", body: ["name": name])
        return answer.machine
    }

    func projects() async throws -> [HerdrProject] {
        struct Answer: Decodable { let projects: [HerdrProject] }
        let answer: Answer = try await projectRoute("/api/projects")
        return answer.projects
    }

    /// Adds a project. The workspace asks the server whether the folder exists, and saves nothing when it does not.
    func addProject(name: String, machine: String, folder: String, note: String) async throws -> HerdrProject {
        struct Answer: Decodable { let project: HerdrProject }
        let answer: Answer = try await projectRoute("/api/projects", method: "POST", body: ["name": name, "machine": machine, "folder": folder, "note": note])
        return answer.project
    }

    func changeProject(_ id: Int, name: String, machine: String, folder: String, note: String) async throws -> HerdrProject {
        struct Answer: Decodable { let project: HerdrProject }
        let answer: Answer = try await projectRoute("/api/projects/\(id)", method: "POST", body: ["name": name, "machine": machine, "folder": folder, "note": note])
        return answer.project
    }

    /// Removes a project; returns the ones left.
    func removeProject(_ id: Int) async throws -> [HerdrProject] {
        struct Answer: Decodable { let projects: [HerdrProject] }
        let answer: Answer = try await projectRoute("/api/projects/\(id)/remove", method: "POST", body: [:])
        return answer.projects
    }

    func agentProjects(_ agent: Agent) async throws -> HerdrAgentProjects { try await projectRoute("/api/agents/\(agent.address)/\(agent.createdMs)/projects") }

    /// Replaces a running agent's projects; an empty list takes all of them away. The agent is not told by this.
    @discardableResult func setAgentProjects(_ ids: [Int], for agent: Agent) async throws -> HerdrAgentProjects {
        try await projectRoute("/api/agents/\(agent.address)/\(agent.createdMs)/projects", method: "POST", body: ["projects": ids])
    }
}

/// What a running agent is told when its bot's projects change. A new agent needs no note from the app: the
/// workspace itself tells it in its first task (`launch_hint` in `projects.rs`), in the same words as `note` here, so
/// an agent that was started with the list it still has is not told twice.
enum HerdrProjectNote {
    /// Words every version of the note has, and the workspace's own first-task sentence too.
    static let lead = "projects on other machines"

    /// The list as it is now; for an empty list, that there are none any more.
    static func note(_ projects: [HerdrBotProject]) -> String {
        guard !projects.isEmpty else { return "You have no projects on other machines any more." }
        return "You may work on these projects on other machines: \(projects.map(\.label).joined(separator: ", ")). Run `swarmhub-herdr project list` to see them and how to run commands and edit files there."
    }
}

/// The words of the project servers' screens, apart from the workspace's own sentences.
enum HerdrProjectsCopy {
    static let olderWorkspace = "This server's Herdr workspace is older and has no project servers. Update swarmhub-herdr on the server, then read again."
    static let title = "Project servers"
    static func intro(_ server: String) -> String { "Your projects may live on other servers than \(server). Add such a server here, name the folders on it that matter as projects, and choose for each bot which projects it may use." }
    /// Said wherever a project is given to a bot.
    static let consequence = "A bot that may use a project can run commands and change files in that folder on that server."
    static func consequence(_ bot: String) -> String { "\(bot) can run commands and change files in the folders of the projects you choose, on the servers they are on." }
    static let notIsolation = "This is not a wall: every agent runs as the same account on the Herdr server, and that account can log in to every project server."

    static let keyTitle = "1. Give the project server this key"
    static func keyDetail(_ server: String) -> String { "\(server) logs in to the project server with its own SSH key. Copy this line and paste it on the project server." }
    static let keyMissing = "The Herdr server has no SSH key pair yet."
    static let keyCreate = "Make a key pair"
    static let addressTitle = "2. Say how to reach it"
    static let addressDetail = "The address as ssh takes it, and a short name to call the server."
    static let addressLabel = "SSH address"
    static let addressPrompt = "deploy@10.0.0.7"
    static let nameLabel = "Name"
    static let namePrompt = "Optional, such as web-1"
    static let add = "Add server"
    static let adding = "Adding the server…"
    static let addingDetail = "The Herdr server is logging in. Copying Herdr's helper program there can take a few minutes."
    static let trustTitle = "Check this server's fingerprint"
    static let trust = "Trust this server"
    static let dontTrust = "Don't trust it"
    static let trustNote = "After this the Herdr server refuses this server if it ever shows another key."
    static let notAdded = "The server was not added"
    static let done = "Done"
    static let another = "Add another server"
    static let cancel = "Cancel"

    /// The workspace's sentence about an unknown host, with its last part (which tells an app what to send) replaced by what to press.
    static func hostKeyQuestion(_ sentence: String) -> String {
        guard let cut = sentence.range(of: " If it matches,") else { return sentence }
        return String(sentence[..<cut.lowerBound]) + " If it matches, press “\(trust)”."
    }

    static let projectsTitle = "Projects"
    static let projectsDetail = "A project is a folder on a project server, by a name your bots use."
    static let noProjects = "No projects yet."
    static let noServers = "No project server yet."
    static let projectName = "Name", projectNamePrompt = "shop"
    static let projectFolder = "Folder", projectFolderPrompt = "/srv/shop"
    static let projectNote = "Note for the bots", projectNotePrompt = "Optional, such as “staging only”"
    static let projectServer = "Server"
    static let addProject = "Add project", newProject = "New project", saveProject = "Save", removeProject = "Remove…"

    static let botTitle = "Projects on other servers"
    static let botNone = "No project is set up yet. Add a project server and a project in Settings → Advanced → Servers and keys → Projects."
    static func botChanged(running: Bool) -> String { running ? "Its running agent has the new list and is told with your next message." : "Its next agent starts with this list." }
    static func botNotApplied(_ reason: String) -> String { "Saved here, but the running agent still has its old list: \(reason)" }

    /// A refusal's own sentence; a workspace without the routes says it is older.
    static func reason(_ error: Error) -> String { error.localizedDescription }
}

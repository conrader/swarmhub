import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentApp

// Project servers: adding one (the Herdr server's key, a host it has not seen, the fingerprint the person trusts),
// listing, reconnecting and removing, projects on a server, which projects a bot may use, what its agent is given and
// told, and the wizard's optional step. The workspace here is scripted; no machine is ever contacted.

/// A workspace that answers the machine, project and agent routes from its own small state, the way the real one
/// answers them from Herdr Core.
private final class ScriptedProjects: @unchecked Sendable {
    static let fingerprint = "SHA256:scriptedFingerprintOfNoRealMachine0000000000"
    private let lock = NSLock()
    private var machines: [(name: String, target: String)] = []
    private var trusted: Set<String> = []
    private var projects: [(id: Int, name: String, machine: String, folder: String, note: String)] = []
    private var nextID = 1
    private var granted: [Int] = []
    private var launched: [[String: Any]] = []
    private var messages: [String] = []
    private var tasks: [String] = []
    private var refusesGrant = false
    private var live = false

    var machineNames: [String] { lock.withLock { machines.map(\.name) } }
    var trustedHosts: Set<String> { lock.withLock { trusted } }
    var agentProjects: [Int] { lock.withLock { granted } }
    var launches: [[String: Any]] { lock.withLock { launched } }
    var sent: [String] { lock.withLock { messages } }
    func run(tasks: [String]) { lock.withLock { live = true; self.tasks = tasks } }
    func refuseGrant(_ refuses: Bool) { lock.withLock { refusesGrant = refuses } }

    private func row(_ machine: (name: String, target: String)) -> [String: Any] {
        ["name": machine.name, "target": machine.target, "host": "host-of-\(machine.name)", "version": "hc 9.9", "state": "connected", "reachable": true, "since_ms": NSNull(), "why": NSNull(),
         "keeps_running_after_logout": false, "warnings": ["Programs started on \(machine.name) stop when the last login there ends."], "projects": projects.filter { $0.machine == machine.name }.map(\.name)]
    }
    private var listing: [String: Any] { ["machines": machines.map(row), "can_add": true, "problem": NSNull(), "adding": "Adding a server copies Herdr's helper program."] }
    private func row(_ project: (id: Int, name: String, machine: String, folder: String, note: String)) -> [String: Any] {
        ["id": project.id, "name": project.name, "machine": project.machine, "folder": project.folder, "note": project.note, "created_ms": 1, "machine_state": "connected", "reachable": true]
    }
    private func refusal(_ status: Int, _ kind: String, _ error: String) -> (Int, Any) { (status, ["error": error, "kind": kind]) }

    func answer(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? "", route = "\(request.httpMethod ?? "GET") \(path)"
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer t" else { return (401, ["error": "no"]) }
        let body = projectsRequestBody(request)
        switch route {
        case "GET /api/machines": return (200, listing)
        case "GET /api/machines/ssh-key":
            return (200, ["keys": [["public_key": "ssh-ed25519 AAAAscripted herdr@scripted", "type": "ssh-ed25519", "fingerprint": "SHA256:scriptedKey", "comment": "herdr@scripted", "file": "/home/x/.ssh/id_ed25519.pub"]],
                          "can_create": false, "where_to_paste": "On the project server, add this line to ~/.ssh/authorized_keys.", "problem": NSNull()])
        case "POST /api/machines":
            guard let target = body["target"] as? String, !target.isEmpty else { return refusal(422, "invalid", "Send target.") }
            if machines.contains(where: { $0.target == target }) { return refusal(409, "already_added", "This server is already added as \(machines.first { $0.target == target }?.name ?? "").") }
            if target.contains("refused") { return refusal(409, "login_refused", "\(target) refused the Herdr server's key. Paste the public key there first.") }
            let host = String(target.split(separator: "@").last ?? "")
            if !trusted.contains(host) {
                guard let accepted = body["accept_host_key"] as? String else {
                    return (409, ["kind": "unknown_host_key", "error": "The Herdr server has not connected to this server before, so it does not know its host key. Compare a fingerprint below with the server's own (on the server: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). If it matches, add \(target) again with accept_host_key set to it.",
                                  "host": host, "host_keys": [["type": "ssh-ed25519", "fingerprint": Self.fingerprint]]])
                }
                guard accepted == Self.fingerprint else { return refusal(409, "unknown_host_key", "\(host) does not show the key you accepted.") }
                trusted.insert(host)
            }
            let name = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            if machines.contains(where: { $0.name == name }) { return refusal(409, "name_taken", "Herdr already has a machine named \(name).") }
            machines.append((name, target))
            return (201, ["machine": row((name, target)), "helper_installed": true, "message": "Added \(name). Herdr's helper program (hc 9.9) was copied to ~/.local/bin on it and started."])
        case "POST /api/machines/remove":
            guard let name = body["name"] as? String, machines.contains(where: { $0.name == name }) else { return refusal(404, "machine_unknown", "Herdr has no machine named \(body["name"] ?? ""). Load the list again.") }
            let held = projects.filter { $0.machine == name }.map(\.name)
            if !held.isEmpty { return (409, ["kind": "has_projects", "error": "\(name) still has projects: \(held.joined(separator: ", ")). Remove them or move them to another server first.", "projects": held]) }
            machines.removeAll { $0.name == name }
            var answer = listing; answer["removed"] = name
            return (200, answer)
        case "POST /api/machines/connect":
            guard let name = body["name"] as? String, let machine = machines.first(where: { $0.name == name }) else { return refusal(404, "machine_unknown", "Herdr has no machine named this. Load the list again.") }
            return (200, ["machine": row(machine)])
        case "GET /api/projects": return (200, ["projects": projects.map(row)])
        case "POST /api/projects":
            guard let name = body["name"] as? String, let machine = body["machine"] as? String, let folder = body["folder"] as? String else { return refusal(422, "invalid", "Send name, machine and folder.") }
            guard machines.contains(where: { $0.name == machine }) else { return refusal(422, "machine_unknown", "Herdr has no machine named \(machine). Add the server first.") }
            if folder.contains("missing") { return refusal(422, "folder_missing", "\(folder) is not a folder on \(machine).") }
            if projects.contains(where: { $0.name == name }) { return refusal(409, "name_taken", "Another project is named \(name).") }
            let project = (nextID, name, machine, folder, body["note"] as? String ?? ""); nextID += 1
            projects.append(project)
            return (201, ["project": row(project)])
        case "GET /api/workspace":
            let agents: [[String: Any]] = live ? [["address": "t1", "created_ms": 5, "name": "ada-abc123", "state": "live", "template": "one", "status": ["state": "done"]]] : []
            return (200, ["core": "core", "version": "9", "agents": agents, "templates": [["name": "one", "description": NSNull(), "error": NSNull(), "runtime": ["harness": "Program One", "provider": NSNull(), "model": NSNull()]]]])
        case "GET /api/profiles": return (200, [])
        case "GET /api/history/core/t1/5": return (200, ["items": tasks.enumerated().map { ["id": $0.offset + 1, "kind": "task", "text": $0.element] }, "before": NSNull()])
        case "GET /api/history/core/t1/5/draft": return (200, ["draft": NSNull(), "tools": []])
        case "POST /api/agents":
            launched.append(body); granted = body["projects"] as? [Int] ?? []; live = true; tasks = [body["task"] as? String ?? ""]
            return (201, ["address": "t1", "created_ms": 5, "name": body["name"] ?? "", "state": "live", "template": "one", "status": NSNull(), "first_message": ["sent": true, "reason": NSNull()]])
        case "POST /api/agents/t1/5/messages":
            let text = body["text"] as? String ?? ""; messages.append(text); tasks.append(text)
            return (200, ["status": "sent"])
        case "GET /api/agents/t1/5/projects": return (200, ["projects": projects.filter { granted.contains($0.id) }.map(row), "inherited": false])
        case "POST /api/agents/t1/5/projects":
            if refusesGrant { return refusal(422, "project_unknown", "A project in the list does not exist. Load the projects again.") }
            granted = body["projects"] as? [Int] ?? []
            return (200, ["projects": projects.filter { granted.contains($0.id) }.map(row), "inherited": false])
        default:
            if path.hasPrefix("/api/projects/"), request.httpMethod == "POST" {
                let parts = path.split(separator: "/"), id = Int(parts[2]) ?? 0
                guard let index = projects.firstIndex(where: { $0.id == id }) else { return refusal(404, "project_unknown", "This project no longer exists. Load the projects again.") }
                if parts.last == "remove" { projects.remove(at: index); granted.removeAll { $0 == id }; return (200, ["removed": id, "projects": projects.map(row)]) }
                if let note = body["note"] as? String { projects[index].note = note }
                if let name = body["name"] as? String { projects[index].name = name }
                if let folder = body["folder"] as? String { projects[index].folder = folder }
                return (200, ["project": row(projects[index])])
            }
            return (404, Data())
        }
    }
}

private func projectsRequestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor private func scripted() -> (server: ScriptedProjects, model: HerdrProjectsModel, client: HerdrClient) {
    let server = ScriptedProjects()
    let (host, session) = MockHTTPProtocol.serve { server.answer($0) }
    let client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
    return (server, HerdrProjectsModel { client }, client)
}

@MainActor @Test func aProjectServerIsAddedOnlyAfterItsFingerprintIsTrusted() async throws {
    let (server, model, _) = scripted()
    await model.load()
    #expect(model.phase == .ready && model.machines.isEmpty && model.projects.isEmpty && model.canAdd)
    #expect(model.publicKey == "ssh-ed25519 AAAAscripted herdr@scripted" && model.keys?.whereToPaste?.contains("authorized_keys") == true, "the Herdr server's own key, to paste on the project server")
    await model.add(); #expect(model.adding == .fields, "nothing is sent without an address")
    model.target = " deploy@10.0.0.7 "; model.name = "box"
    await model.add()
    guard case .trust(let question) = model.adding else { Issue.record("a host the Herdr server has not seen is not added: \(model.adding)"); return }
    #expect(question.kind == "unknown_host_key" && question.host == "10.0.0.7" && question.hostKeys.map(\.fingerprint) == [ScriptedProjects.fingerprint])
    #expect(server.machineNames.isEmpty && server.trustedHosts.isEmpty, "showing the fingerprint trusts nothing and adds nothing")
    #expect(HerdrProjectsCopy.hostKeyQuestion(question.message).hasSuffix("If it matches, press “Trust this server”.") && !HerdrProjectsCopy.hostKeyQuestion(question.message).contains("accept_host_key"))
    await model.trust(HerdrRefusal.HostKey(type: "ssh-ed25519", fingerprint: "SHA256:another"))
    #expect(server.trustedHosts.isEmpty && model.adding == .trust(question), "only a fingerprint that was shown can be trusted")
    await model.trust(question.hostKeys[0])
    guard case .done(let message, let warnings) = model.adding else { Issue.record("not added: \(model.adding)"); return }
    #expect(message.contains("Added box") && message.contains("helper program") && warnings.count == 1, "the result says what was installed there, with the server's warnings")
    #expect(server.machineNames == ["box"] && server.trustedHosts == ["10.0.0.7"] && model.machines.map(\.name) == ["box"] && model.target.isEmpty && model.name.isEmpty)
    #expect(model.machines[0].stateLine == "Connected" && model.machines[0].target == "deploy@10.0.0.7")
}

@MainActor @Test func refusalsAreShownInTheWorkspacesOwnSentence() async throws {
    let (server, model, client) = scripted()
    await model.load()
    model.target = "deploy@refused.example"; await model.add()
    #expect(model.adding == .failed("deploy@refused.example refused the Herdr server's key. Paste the public key there first.") && model.target == "deploy@refused.example", "what was typed stays for another try")
    model.addAgain(); model.target = "deploy@10.0.0.7"; model.name = "box"; await model.add()
    if case .trust(let question) = model.adding { await model.trust(question.hostKeys[0]) }
    model.addAgain(); model.target = "deploy@10.0.0.7"; await model.add()
    #expect(model.adding == .failed("This server is already added as box."))
    model.addAgain()
    // A server that still has projects is not removed; reconnecting answers with the server as it is now.
    model.newProject(); model.draft?.name = "shop"; model.draft?.folder = "/srv/shop"
    #expect(model.draft?.machine == "box" && model.draft?.isComplete == true)
    #expect(await model.saveProject()?.name == "shop" && model.draft == nil && model.machines[0].projects == ["shop"])
    await model.remove(model.machines[0])
    #expect(server.machineNames == ["box"] && model.said["box"] == "box still has projects: shop. Remove them or move them to another server first.")
    await model.reconnect(model.machines[0]); #expect(model.said["box"] == "box is connected.")
    await model.removeProject(model.projects[0]); await model.remove(model.machines[0])
    #expect(server.machineNames.isEmpty && model.machines.isEmpty && model.projects.isEmpty)
    // The routes' own refusals carry a kind; a workspace without the routes is an older one.
    do { _ = try await client.removeMachine("gone"); Issue.record("an unknown server is refused") }
    catch { #expect((error as? HerdrRefusal)?.kind == "machine_unknown" && error.localizedDescription.contains("Load the list again")) }
    let (old, oldSession) = MockHTTPProtocol.serve { _ in (404, Data()) }
    let older = HerdrProjectsModel { HerdrClient(baseURL: URL(string: "http://\(old)")!, token: "t", session: oldSession) }
    await older.load()
    #expect(older.phase == .unavailable(HerdrProjectsCopy.olderWorkspace))
    let (denied, deniedSession) = MockHTTPProtocol.serve { _ in (401, ["error": "no"]) }
    do { _ = try await HerdrClient(baseURL: URL(string: "http://\(denied)")!, token: "x", session: deniedSession).machines(); Issue.record("a wrong access key is refused") }
    catch { #expect((error as? HerdrClient.Failure) == .unauthorized) }
}

@MainActor @Test func projectsAreAddedChangedAndRemoved() async throws {
    let (_, model, client) = scripted()
    await model.load()
    model.target = "deploy@10.0.0.7"; model.name = "box"; await model.add()
    if case .trust(let question) = model.adding { await model.trust(question.hostKeys[0]) }
    model.newProject()
    #expect(model.draft?.isComplete == false, "a project needs a name and a folder")
    model.draft?.name = "shop"; model.draft?.folder = "srv/shop"; #expect(model.draft?.isComplete == false, "the folder is a full path")
    model.draft?.folder = "/srv/missing"
    #expect(await model.saveProject() == nil && model.projectProblem == "/srv/missing is not a folder on box." && model.draft?.name == "shop", "a folder that is not there saves nothing and keeps what was typed")
    model.draft?.folder = "/srv/shop"; model.draft?.note = " staging only "
    let shop = try #require(await model.saveProject())
    #expect(shop.folder == "/srv/shop" && shop.note == "staging only" && shop.label == "shop (on box)" && model.projects == [shop] && model.projectProblem.isEmpty)
    model.edit(shop); model.draft?.note = "production"
    #expect(await model.saveProject()?.note == "production" && model.projects.count == 1 && model.projects[0].note == "production")
    #expect(try await client.projects().map(\.name) == ["shop"])
    await model.removeProject(model.projects[0]); #expect(model.projects.isEmpty)
    do { _ = try await client.changeProject(99, name: "x", machine: "box", folder: "/x", note: ""); Issue.record("a project that is gone is refused") }
    catch { #expect((error as? HerdrRefusal)?.kind == "project_unknown") }
}

/// What a running agent is told about its projects, and when: once per change, in the words the workspace itself
/// uses for a new agent, and never that it has none when it never had any.
@Test func aRunningAgentIsToldItsProjectsOncePerChange() {
    let shop = HerdrBotProject(id: 1, name: "shop", machine: "box"), docs = HerdrBotProject(id: 2, name: "docs", machine: "box")
    let one = HerdrProjectNote.note([shop]), two = HerdrProjectNote.note([shop, docs]), none = HerdrProjectNote.note([])
    #expect(one == "You may work on these projects on other machines: shop (on box). Run `swarmhub-herdr project list` to see them and how to run commands and edit files there.", "the workspace's own first-task sentence")
    #expect([one, two, none].allSatisfy { $0.contains(HerdrProjectNote.lead) } && two.contains("shop (on box), docs (on box)"))
    func notes(_ list: [HerdrBotProject], _ tasks: [String]) -> [String] {
        HerdrClient.notes(reminder: nil, once: [], tasks: tasks, revised: [(HerdrProjectNote.lead, HerdrProjectNote.note(list), list.isEmpty)])
    }
    #expect(notes([], ["hi"]).isEmpty, "an agent that never had a project is not told that it has none")
    #expect(notes([shop], ["hi"]) == [one], "an agent that started without projects learns its first")
    #expect(notes([shop], ["Be brief.\n\n\(one)\n\nMy first message:\nhi"]).isEmpty, "an agent the workspace already told is not told again")
    #expect(notes([shop], ["hi", one + "\n\nnext"]).isEmpty && notes([shop, docs], ["hi", one + "\n\nnext"]) == [two], "told once, and again when the list changes")
    #expect(notes([], ["hi", one + "\n\nnext"]) == [none] && notes([], ["hi", one + "\n\nnext", none + "\n\nmore"]).isEmpty, "and once that they are gone")
    #expect(notes([shop], ["hi", one + "\n\na", none + "\n\nb"]) == [one], "a project given back is announced again")
}

@Test func aNewAgentStartsWithItsProjectsAndARunningOneIsGivenTheNewList() async throws {
    let server = ScriptedProjects()
    let (host, session) = MockHTTPProtocol.serve { server.answer($0) }
    let client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
    let shop = HerdrBotProject(id: 1, name: "shop", machine: "box"), docs = HerdrBotProject(id: 2, name: "docs", machine: "box")
    let heard = LockedTrace()
    // A new agent: the launch names the projects, and the app adds no note of its own (the workspace tells it).
    let turn = try await client.deliver("hi", name: "ada-abc123", template: nil, projects: [shop], resync: true, synced: { heard.add("synced") })
    #expect(turn.launched && server.launches.count == 1 && server.launches[0]["projects"] as? [Int] == [1] && heard.read() == ["synced"])
    #expect(server.launches[0]["task"] as? String == "hi" && server.agentProjects == [1])
    // A launch with no projects sends none.
    let plain = ScriptedProjects(); let (plainHost, plainSession) = MockHTTPProtocol.serve { plain.answer($0) }
    _ = try await HerdrClient(baseURL: URL(string: "http://\(plainHost)")!, token: "t", session: plainSession).deliver("hi", name: "ada-abc123", template: nil)
    #expect(plain.launches[0]["projects"] == nil)
    // The agent the workspace told about shop: nothing more is said while the list stays.
    server.run(tasks: [HerdrProjectNote.note([shop]) + "\n\nMy first message:\nhi"])
    _ = try await client.deliver("again", name: "ada-abc123", template: nil, projects: [shop])
    #expect(server.sent == ["again"] && heard.read() == ["synced"])
    // The list changed: the running agent is given it first, then told in front of the message.
    _ = try await client.deliver("go", name: "ada-abc123", template: nil, projects: [shop, docs], resync: true, synced: { heard.add("synced") })
    #expect(server.agentProjects == [1, 2] && server.sent.last == HerdrProjectNote.note([shop, docs]) + "\n\ngo" && heard.read() == ["synced", "synced"])
    // A list the workspace refuses is not announced, and the message still goes.
    server.refuseGrant(true)
    _ = try await client.deliver("still", name: "ada-abc123", template: nil, projects: [docs], resync: true, synced: { heard.add("synced") })
    #expect(server.agentProjects == [1, 2] && server.sent.last == "still" && heard.read().count == 2, "the agent keeps the list it has, and is not told otherwise")
    server.refuseGrant(false)
    _ = try await client.deliver("now", name: "ada-abc123", template: nil, projects: [], resync: true, synced: { heard.add("synced") })
    #expect(server.agentProjects.isEmpty && server.sent.last == HerdrProjectNote.note([]) + "\n\nnow")
    let live = try #require(client.liveAgent(named: "ada-abc123", in: try await client.workspace()))
    let now = try await client.agentProjects(live)
    #expect(now.projects.isEmpty && now.inherited == false)
}

@MainActor @Test func aBotsProjectsAreKeptWithItAndGoToItsAgent() throws {
    let defaults = isolatedDefaults(), store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let box = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com", sshUser: "deploy")
    store.saveHerdrServer(box, token: "t")
    let ada = Bot(name: "Ada", backend: .herdr); store.bots = [ada]
    let plain = try store.herdrBackend(for: ada)
    #expect(store.herdrProjects(for: ada).isEmpty && !store.herdrProjectsChanged(ada) && plain.projects.isEmpty && !plain.projectsChanged, "no project unless the person chose one")
    let shop = HerdrBotProject(id: 1, name: "shop", machine: "box"), docs = HerdrBotProject(id: 2, name: "docs", machine: "box")
    store.setHerdrProjects([shop, docs], for: ada)
    let backend = try store.herdrBackend(for: ada)
    #expect(store.herdrProjects(for: ada) == [shop, docs] && backend.projects == [shop, docs] && backend.projectsChanged, "its next message gives the list to a running agent")
    #expect(backend.launchInstructions?.contains(HerdrProjectNote.lead) != true, "a new agent is told by the workspace, not by the app's notes")
    defaults.removeObject(forKey: AppStore.herdrProjectsChangedKey(ada.id))
    store.setHerdrProjects([shop, docs], for: ada); #expect(!store.herdrProjectsChanged(ada), "the same list again changes nothing")
    // The server's list was read: a renamed project takes its new name, a removed one leaves the bot's list.
    store.reconcileHerdrProjects(on: store.herdrServers[0], with: [HerdrProject(id: 1, name: "store", machine: "box", folder: "/srv/shop")])
    #expect(store.herdrProjects(for: ada) == [HerdrBotProject(id: 1, name: "store", machine: "box")] && store.herdrProjectsChanged(ada))
    #expect(store.herdrProjectsModel(for: box) === store.herdrProjectsModel(for: box) && store.herdrProjectsModel(for: box) !== store.herdrProjectsModel(for: store.herdrServers[0]), "one per Herdr server")
    // Projects belong to a Herdr server: a bot whose server is removed does not take them along.
    store.setHerdrServer("box1", for: ada); store.setHerdrProjects([shop], for: ada)
    store.removeHerdrServer(box)
    #expect(store.herdrProjects(for: ada).isEmpty && store.herdrServer(for: ada).id == store.herdrServers[0].id)
}

private let stepServer = HerdrServer(id: "box1", name: "Box", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "box.example.com", sshUser: "deploy")
private let stepOne = HerdrProgram(template: "one", name: "Program One", takesModel: true, models: [.init(id: "first-model", label: "First")])
private let stepTwo = HerdrProgram(template: "two", name: "Program Two", takesModel: true, models: [.init(id: "other-model", label: nil)])

@Test func theWizardOffersProjectsAsItsLastOptionalStep() {
    var flow = SetupFlow(); flow.apply(.pickHerdr(.ssh)); flow.herdr.sshHost = "box.example.com"
    flow.apply(.herdrTest(.connected(server: stepServer, key: "k", offer: HerdrOffer(programs: [stepOne, stepTwo], projectServers: true)))); flow.apply(.advance)
    #expect(flow.step == .mainBot && flow.offersProjects && !flow.isLastWizardStep && flow.stepCount == 5 && flow.stepIndex == 2)
    flow.apply(.advance); #expect(flow.step == .moreBots && !flow.isLastWizardStep && flow.stepIndex == 3, "the optional bots are no longer the end")
    flow.moreBots = ["two"]; flow.apply(.advance)
    #expect(flow.step == .projects && flow.isLastWizardStep && flow.stepIndex == 4 && flow.moreChosen == [stepTwo] && flow.mainProjects.isEmpty, "nothing is chosen, so skipping it changes nothing")
    flow.apply(.advance); #expect(flow.step == .projects, "there is no step after it")
    flow.apply(.back); #expect(flow.step == .moreBots); flow.apply(.advance)
    // A server with one agent program goes from the main bot straight to the projects.
    var single = SetupFlow(); single.apply(.pickHerdr(.ssh)); single.herdr.sshHost = "box.example.com"
    single.apply(.herdrTest(.connected(server: stepServer, key: nil, offer: HerdrOffer(programs: [stepOne], projectServers: true)))); single.apply(.advance)
    #expect(single.step == .mainBot && !single.isLastWizardStep && single.stepCount == 4)
    single.apply(.advance); #expect(single.step == .projects && single.isLastWizardStep && single.stepIndex == 3)
    // A server whose workspace has no project servers keeps the wizard as it was.
    var older = SetupFlow(); older.apply(.pickHerdr(.ssh)); older.herdr.sshHost = "box.example.com"
    older.apply(.herdrTest(.connected(server: stepServer, key: nil, offer: HerdrOffer(programs: [stepOne, stepTwo])))); older.apply(.advance); older.apply(.advance)
    #expect(older.step == .moreBots && older.isLastWizardStep && !older.offersProjects && older.stepCount == 4)
    older.apply(.advance); #expect(older.step == .moreBots)
    #expect(WizardCopy.stepLabel(4, of: 5, name: WizardCopy.projectsStep) == "Step 5 of 5: Projects" && WizardCopy.projectsIntro(server: "Box", main: "Ada").hasPrefix("Optional."))
    #expect(HerdrProjectsCopy.consequence("Ada").contains("run commands and change files") && HerdrProjectsCopy.consequence.contains("run commands and change files"), "said plainly wherever a project is given to a bot")
}

@MainActor @Test func theWizardsLastButtonGivesTheMainBotItsProjects() throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let offer = HerdrOffer(programs: [stepOne, stepTwo], projectServers: true)
    var main = HerdrMainBotDraft(); main.begin(offer: offer, bots: []); main.name = "Ada"
    let shop = HerdrBotProject(id: 1, name: "shop", machine: "box"), docs = HerdrBotProject(id: 2, name: "docs", machine: "box")
    let ada = try store.commitSetupWizard(server: stepServer, key: "k", main: main, more: [stepTwo], offer: offer, projects: [shop])
    let started = try store.herdrBackend(for: ada)
    #expect(store.herdrProjects(for: ada) == [shop] && store.herdrProjects(for: store.bots[1]).isEmpty && started.projects == [shop], "the main bot's first agent starts with them; no other bot gets any")
    // A main bot that stays keeps what it has and gains what was chosen.
    var again = HerdrMainBotDraft(); again.begin(offer: offer, bots: store.setupHerdrBots(on: stepServer))
    #expect(again.keep == ada.id)
    #expect(try store.commitSetupWizard(server: stepServer, key: nil, main: again, more: [], offer: offer, projects: [shop, docs]) === ada && store.herdrProjects(for: ada) == [shop, docs])
    #expect(try store.commitSetupWizard(server: stepServer, key: nil, main: again, more: [], offer: offer) === ada && store.herdrProjects(for: ada) == [shop, docs], "skipping the step takes nothing away")
}

/// The step and the Projects part of Settings render in each of their states, each differently.
@MainActor @Test func theProjectScreensRender() async throws {
    let store = SetupPreview.makeStore(); store.isSetupPreview = false
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let states = HeadlessHerdrShots.projectModels()
    #expect(states.count == HeadlessHerdrShots.projects.count)
    var flow = SetupFlow(); flow.apply(.pickHerdr(.ssh)); flow.herdr.sshHost = "box.example.com"
    flow.apply(.herdrTest(.connected(server: stepServer, key: nil, offer: HerdrOffer(programs: [stepOne], projectServers: true)))); flow.apply(.advance); flow.apply(.advance)
    #expect(flow.step == .projects)
    var sizes: [Int] = []
    for index in 0..<5 {
        let data = try #require(await HeadlessSetup.png(SetupView(preset: flow, presetProjects: states[index], presetHeight: 860), store: store, updater: updater, size: NSSize(width: HeadlessSetup.size.width, height: 860)))
        #expect(data.count > 4_000, "\(HeadlessHerdrShots.projects[index]) looks blank"); sizes.append(data.count)
    }
    for index in [5, 6] {
        let size = NSSize(width: 570, height: 1_180)
        let view = HerdrProjectsSection(server: stepServer, preset: states[index]).padding(28).frame(width: size.width, height: size.height, alignment: .top)
        let data = try #require(await HeadlessSetup.png(view, store: store, updater: updater, size: size))
        #expect(data.count > 4_000); sizes.append(data.count)
    }
    #expect(Set(sizes).count == sizes.count)
    #expect(store.bots.isEmpty && store.defaults.string(forKey: HerdrServer.listKey) == nil, "showing them writes nothing")
}

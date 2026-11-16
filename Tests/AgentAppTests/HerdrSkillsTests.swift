import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentApp

// A Herdr server's skill library: what the workspace reports, the switches with their sync, sharing with another
// agent program behind a confirmation, and a server that has no skillshare. The server here is scripted.

/// A workspace that answers the skillshare routes from its own small state, like the real one does from skillshare.
private final class ScriptedSkills: @unchecked Sendable {
    private let lock = NSLock()
    private var skills: [(name: String, description: String?, enabled: Bool)] = [("alpha", "First skill.", true), ("beta", nil, true), ("gamma", "Reviews a diff.", false)]
    private var targets: [(name: String, linked: Int)] = [("one", 2), ("two", 2)]
    private var syncFails = false
    private var counts: [String: Int] = [:]

    func failSync(_ fails: Bool) { lock.withLock { syncFails = fails } }
    func asked(_ route: String) -> Int { lock.withLock { counts[route] ?? 0 } }
    var linked: [Int] { lock.withLock { targets.map(\.linked) } }
    var enabled: [String] { lock.withLock { skills.filter(\.enabled).map(\.name) } }

    private var targetRows: [[String: Any]] { targets.map { ["name": $0.name, "path": "/home/x/.\($0.name)/skills", "mode": "merge", "status": "merged", "linked": $0.linked, "skills_enabled": true] } }
    private var library: [String: Any] {
        ["installed": true, "version": "9.9", "problem": NSNull(), "source": "/home/x/skills", "skill_count": skills.count,
         "skills": skills.map { ["name": $0.name, "path": $0.name, "description": $0.description ?? NSNull() as Any, "enabled": $0.enabled, "origin": "local", "source": NSNull()] }, "targets": targetRows]
    }

    func answer(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        counts[route, default: 0] += 1
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer t" else { return (401, ["error": "no"]) }
        let body = skillsRequestBody(request)
        switch route {
        case "GET /api/skillshare": return (200, library)
        case "POST /api/skillshare/enable", "POST /api/skillshare/disable":
            let on = route.hasSuffix("enable")
            guard let name = body["name"] as? String, let index = skills.firstIndex(where: { $0.name == name }) else { return (404, ["error": "skillshare lists no skill with this name. Load the list again."]) }
            let changed = skills[index].enabled != on
            skills[index].enabled = on
            var answer = library; answer["changed"] = changed ? [name] : []; answer["output"] = changed ? "done" : ""
            return (200, answer)
        case "POST /api/skillshare/sync":
            let on = skills.filter(\.enabled).count, dry = body["dry_run"] as? Bool ?? false
            if !dry, syncFails { return (504, ["error": "skillshare took too long and was stopped."]) }
            let details = targets.map { ["name": $0.name, "linked": on, "local": 0, "updated": 0, "pruned": max(0, $0.linked - on)] as [String: Any] }
            let pruned = targets.map { max(0, $0.linked - on) }.reduce(0, +)
            if !dry { targets = targets.map { ($0.name, on) } }
            return (200, ["dry_run": dry, "linked": on * targets.count, "local": 0, "updated": 0, "pruned": pruned, "ignored": 0, "details": details, "targets": targetRows, "problem": NSNull()])
        case "GET /api/skillshare/targets/addable": return (200, ["installed": true, "problem": NSNull(), "agents": ["three"]])
        case "POST /api/skillshare/targets":
            guard let agent = body["agent"] as? String, agent == "three" else { return (422, ["error": "skillshare does not offer this agent program on this server."]) }
            if targets.contains(where: { $0.name == agent }) { return (409, ["error": "three is already a Target."]) }
            targets.append((agent, 0))
            return (200, ["installed": true, "version": "9.9", "problem": NSNull(), "targets": targetRows, "added": agent, "output": "added"])
        default: return (404, Data())
        }
    }
}

private func skillsRequestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor private func scripted() -> (server: ScriptedSkills, model: HerdrSkillsModel, client: HerdrClient) {
    let server = ScriptedSkills()
    let (host, session) = MockHermesProtocol.serve { server.answer($0) }
    let client = HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session)
    return (server, HerdrSkillsModel { client }, client)
}

@MainActor @Test func theSkillLibraryIsReadWithWhatItIsSharedWith() async throws {
    let (server, model, client) = scripted()
    #expect(model.phase == .idle && model.library == nil)
    await model.load()
    let library = try #require(model.library)
    #expect(model.phase == .ready && library.installed && library.skills.map(\.name) == ["alpha", "beta", "gamma"] && library.enabledCount == 2 && library.hiddenCount == 0)
    #expect(library.sharedLine == "Shared with one (2 skills) and two (2 skills)." && library.skills[0].description == "First skill." && library.skills[1].description == nil)
    #expect(library.matching("REVIEW").map(\.name) == ["gamma"] && library.matching("alp").map(\.name) == ["alpha"] && library.matching("  ").count == 3 && library.matching("zzz").isEmpty)
    #expect(model.behind == nil && server.asked("POST /api/skillshare/sync") == 1, "one dry run asks whether a sync is waiting")
    #expect(server.asked("GET /api/skillshare/targets/addable") == 0, "the discovery is never run by a read")
    // The times the server allows skillshare, and a little more.
    #expect(HerdrClient.skillReadSeconds > 20 && HerdrClient.skillChangeSeconds > 60 && HerdrClient.skillSyncSeconds > 120)
    #expect(try client.request("/api/skillshare/sync", method: "POST", body: nil, timeout: HerdrClient.skillSyncSeconds).timeoutInterval == HerdrClient.skillSyncSeconds)
}

@MainActor @Test func aSwitchChangesTheLibraryAndThenTheAgentPrograms() async throws {
    let (server, model, _) = scripted()
    await model.load()
    let beta = try #require(model.library?.skills[1])
    model.set(beta, on: false)
    #expect(!model.isOn(beta) && model.isChanging(beta) && model.isBusy, "the switch shows at once")
    await model.settled()
    #expect(server.enabled == ["alpha"] && server.linked == [1, 1], "the library changed, and the sync brought it to the agent programs")
    #expect(model.library?.skills[1].enabled == false && model.library?.targets.map(\.linked) == [1, 1] && model.behind == nil && !model.isBusy)
    #expect(model.note == "beta is off. The agent programs are up to date: one (1 skill) and two (1 skill).", "\(model.note)")
    // Several switches in a row go one after another, and one sync follows the last.
    let syncs = server.asked("POST /api/skillshare/sync")
    let skills = try #require(model.library?.skills)
    model.set(skills[1], on: true); model.set(skills[2], on: true)
    await model.settled()
    #expect(server.enabled == ["alpha", "beta", "gamma"] && server.linked == [3, 3] && server.asked("POST /api/skillshare/sync") == syncs + 1)
    // A skill that is not there any more: the server's own sentence, and the switch goes back.
    model.set(HerdrSkillLibrary.Skill(name: "gone", path: "gone", enabled: false), on: true)
    await model.settled()
    #expect(model.note == "skillshare lists no skill with this name. Load the list again." && model.wanted.isEmpty && server.asked("POST /api/skillshare/sync") == syncs + 1)
}

@MainActor @Test func aSyncThatFailsSaysTheSwitchChangedAndOffersRetry() async throws {
    let (server, model, _) = scripted()
    await model.load()
    server.failSync(true)
    model.set(try #require(model.library?.skills[0]), on: false)
    await model.settled()
    #expect(server.enabled == ["beta"] && server.linked == [2, 2], "the library changed; the agent programs did not")
    #expect(model.behind == .failed("alpha was turned off in the library, but the agent programs have not been updated: skillshare took too long and was stopped."), "\(String(describing: model.behind))")
    #expect(model.library?.skills[0].enabled == false)
    // Reading again keeps saying so (the dry run still finds a sync waiting); Retry brings it over.
    await model.load()
    #expect(model.behind != nil)
    server.failSync(false)
    await model.sync()
    #expect(model.behind == nil && server.linked == [1, 1] && model.note.contains("The agent programs are up to date: one (1 skill) and two (1 skill)."))
    // A sync left waiting by someone else is found by a fresh read.
    let (other, fresh, client) = scripted()
    _ = try await client.setSkill("alpha", enabled: false)
    await fresh.load()
    #expect(fresh.behind == .waiting && other.linked == [2, 2])
}

@MainActor @Test func sharingWithAnotherAgentProgramNeedsAnExplicitYes() async throws {
    let (server, model, _) = scripted()
    await model.load()
    #expect(model.sharing == .closed && server.asked("GET /api/skillshare/targets/addable") == 0)
    await model.openSharing()
    #expect(model.sharing == .offered(["three"]) && server.asked("GET /api/skillshare/targets/addable") == 1 && model.confirming == nil)
    await model.share(with: "three")
    #expect(server.asked("POST /api/skillshare/targets") == 0, "nothing is added before the person confirms")
    model.confirming = "three"
    let warning = HerdrSkillsCopy.shareConsequence("three", server: "Box", count: 2)
    #expect(warning.contains("Every session of three on Box") && warning.contains("outside \(AppConstants.name)") && warning.contains("cannot be cleanly undone"))
    await model.share(with: "three")
    #expect(server.asked("POST /api/skillshare/targets") == 1 && model.sharing == .closed && model.confirming == nil)
    #expect(model.library?.targets.map(\.name) == ["one", "two", "three"] && server.linked == [2, 2, 2], "the sync after it links the skills into the new program's folder")
    #expect(model.note == "The library is now shared with three. The agent programs are up to date: one (2 skills), two (2 skills) and three (2 skills).", "\(model.note)")
    model.closeSharing(); #expect(model.sharing == .closed)
}

@MainActor @Test func aServerWithoutSkillshareSaysWhy() async throws {
    let missing = #"{"installed":false,"version":null,"problem":"skillshare is not installed on this server.","source":null,"skill_count":0,"skills":[],"targets":[]}"#
    let (host, session) = MockHermesProtocol.serve { request in
        if request.url?.path == "/api/skillshare" { return (200, Data(missing.utf8)) }
        return (503, ["error": "skillshare is not installed on this server."])
    }
    let model = HerdrSkillsModel { HerdrClient(baseURL: URL(string: "http://\(host)")!, token: "t", session: session) }
    await model.load()
    #expect(model.phase == .ready && model.library?.installed == false && model.library?.problem == "skillshare is not installed on this server." && model.behind == nil)
    #expect(MockHermesProtocol.recorded(host).count == 1, "nothing else is asked of a server without skillshare")
    // An older workspace has no such route.
    let (old, oldSession) = MockHermesProtocol.serve { _ in (404, Data()) }
    let older = HerdrSkillsModel { HerdrClient(baseURL: URL(string: "http://\(old)")!, token: "t", session: oldSession) }
    await older.load()
    #expect(older.phase == .unavailable(HerdrSkillsCopy.olderWorkspace))
}

@MainActor @Test func aHerdrBotsDetailsShowItsServersSkills() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.saveHerdrServer(store.herdrServers[0], token: "t")
    let bot = Bot(name: "Ada", backend: .herdr); store.bots = [bot]
    #expect(store.infoTabs(for: bot) == [.overview, .model, .skills, .media])
    #expect(store.herdrSkillsModel(for: store.herdrServers[0]) === store.herdrSkillsModel(for: store.herdrServer(for: bot)), "Settings and Details show the same section")
    // The section renders in each of its states, each differently.
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"]), size = NSSize(width: 760, height: 640)
    var sizes: [Int] = []
    for model in HeadlessHerdrShots.skillModels().dropLast() {
        let view = Form { HerdrSkillsSection(server: store.herdrServers[0], preset: model) }.formStyle(.grouped).frame(width: size.width, height: size.height)
        let data = try #require(await HeadlessSetup.png(view, store: store, updater: updater, size: size))
        #expect(data.count > 4_000); sizes.append(data.count)
    }
    #expect(Set(sizes).count == sizes.count && HeadlessHerdrShots.skills.count == HeadlessHerdrShots.skillModels().count)
}

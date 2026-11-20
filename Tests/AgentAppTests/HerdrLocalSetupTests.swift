import AppKit
import Foundation
import Testing
@testable import AgentApp

// "This Mac": what the service on it says, how the app runs it, how the wizard offers to set a Mac up, and how it
// finds out that an AI still has a question for the person.

private let statusJSON = #"""
{"access_key":true,"agents_folder":"/Users/ada/swarmhub-agents","can_install":true,
 "core":{"installed":true,"path":"/Users/ada/.local/bin/hc","running":true,"socket":"/x/default.sock","version":"0.1.21"},
 "data_folder":"/Users/ada/.local/state/swarmhub-herdr","did":["Made the access key."],"ok":true,"port":8787,
 "program":"/Users/ada/.local/bin/swarmhub-herdr",
 "programs":[{"full_name":"Program One","how":"Install One.","first_time":"One asks once.","id":"one","installed":true,"name":"One","path":"/bin/one","template":"starter-one","template_written":true},
             {"full_name":"Program Two","how":"Install Two.","id":"two","installed":false,"name":"Two","path":null,"template":"starter-two","template_written":false}],
 "service":{"answers":true,"installed":true,"job":"/x.plist","label":"com.example.job","loaded":true,"log":"/x.log","pid":4242},
 "target":"aarch64-macos","version":"0.8.0"}
"""#

@Test func theAppReadsWhatTheServiceSaysAboutThisMac() throws {
    let report: HerdrLocalReport = try HerdrLocalService.answer(Data(statusJSON.utf8))
    #expect(report.version == "0.8.0" && report.port == 8787 && report.canInstall && report.core.version == "0.1.21" && report.service.pid == 4242)
    #expect(report.did == ["Made the access key."] && report.missing.map(\.name) == ["Two"] && report.missing[0].how == "Install Two.")
    #expect(report.program(template: "starter-one")?.firstTime == "One asks once." && report.program(template: "starter-two")?.firstTime == nil)
    let removal: HerdrLocalRemoval = try HerdrLocalService.answer(Data(#"{"ok":true,"did":["Stopped."],"kept":["Your conversations."]}"#.utf8))
    #expect(removal == HerdrLocalRemoval(did: ["Stopped."], kept: ["Your conversations."]))
    // A refusal keeps the service's own sentence and its word; anything else is said plainly.
    #expect(throws: HerdrLocalFailure(kind: "port_busy", message: "Another program uses it.")) {
        let _: HerdrLocalReport = try HerdrLocalService.answer(Data(#"{"ok":false,"error":"Another program uses it.","kind":"port_busy"}"#.utf8))
    }
    #expect(throws: HerdrLocalFailure.self) { let _: HerdrLocalReport = try HerdrLocalService.answer(Data("not json".utf8)) }
    let service = HerdrLocalService(home: "/Users/ada", label: "com.example.job")
    #expect(service.programPath == "/Users/ada/.local/bin/swarmhub-herdr")
    #expect(service.arguments("install", port: 8790) == ["service", "install", "--port", "8790", "--label", "com.example.job", "--json"])
    #expect(HerdrLocalService(home: "/Users/ada").arguments("remove", port: nil) == ["service", "remove", "--json"])
    #expect(HerdrLocalService(home: "/Users/ada").arguments("install", port: 8787, extra: ["--answer-first-time"]) == ["service", "install", "--port", "8787", "--answer-first-time", "--json"])
    let answered: HerdrLocalReport = try HerdrLocalService.answer(Data(statusJSON.replacingOccurrences(of: #""ok":true,"#, with: #""ok":true,"first_time":[{"id":"one","done":true,"changed":true,"what":"Told One."},{"id":"two","done":false,"changed":false,"why":"Two will ask."}],"#).utf8))
    #expect(answered.firstTime == [.init(id: "one", done: true, what: "Told One."), .init(id: "two", done: false, why: "Two will ask.")])
    #expect(["aarch64-macos", "x86_64-macos"].contains(HerdrLocalService.target))
}

/// A stand-in for the service program: a script that answers like it. The app puts a program in place in one
/// step, runs it with the home folder it was given, and reads its answer or its refusal.
@Test func theAppPutsTheServiceInPlaceAndRunsIt() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    var service = HerdrLocalService(home: home.path)
    #expect(!service.isPlaced && !service.hasCore)
    let script = """
        #!/bin/sh
        echo "$HOME $SWARMHUB_CHECK $*" >> "$HOME/calls"
        case "$2" in
          install) echo '{"ok":false,"error":"Another program on this Mac already uses port 8790. Choose another port.","kind":"port_busy"}'; exit 1 ;;
          remove) echo '{"ok":true,"did":["Stopped the service."],"kept":["Your conversations."]}' ;;
          *) cat "$HOME/status.json" ;;
        esac
        """
    try service.place(Data(script.utf8))
    #expect(service.isPlaced && FileManager.default.isExecutableFile(atPath: service.programPath))
    #expect(!FileManager.default.fileExists(atPath: service.programPath + ".new"))
    try Data(statusJSON.utf8).write(to: home.appendingPathComponent("status.json"))
    service.environment = ["SWARMHUB_CHECK": "yes"]
    #expect(try await service.status(port: 8787).programs.count == 2)
    await #expect(throws: HerdrLocalFailure(kind: "port_busy", message: "Another program on this Mac already uses port 8790. Choose another port.")) { _ = try await service.install(port: 8790) }
    #expect(try await service.remove().did == ["Stopped the service."])
    let calls = try String(contentsOf: home.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(calls == ["\(home.path) yes service status --port 8787 --json", "\(home.path) yes service install --port 8790 --json", "\(home.path) yes service remove --json"])
    // Putting a newer program there replaces the old one.
    try service.place(Data("#!/bin/sh\necho '{\"ok\":false,\"error\":\"second\"}'\n".utf8))
    await #expect(throws: HerdrLocalFailure(kind: "failed", message: "second")) { _ = try await service.status() }
    try FileManager.default.removeItem(atPath: service.programPath)
    await #expect(throws: HerdrLocalFailure.self) { _ = try await service.status() }
}

@Test func aMacWithNothingRunningIsOfferedSetupAndSaysWhyItStopped() {
    var flow = SetupFlow(); flow.apply(.pickHerdr(.local)); flow.apply(.herdrTest(.nothingHere(port: 8787)))
    #expect(flow.localSetup == nil)
    flow.apply(.localSetup(.offer(hasCore: false)))
    #expect(flow.localSetup == .offer(hasCore: false) && flow.localSetup?.isWorking == false && !flow.herdrReady)
    flow.apply(.localSetup(.working(.checkingRelease))); #expect(flow.localSetup?.isWorking == true)
    flow.apply(.localSetup(.failed("No.")))
    // Trying again finds nothing still: the reason stays on screen.
    flow.apply(.herdrTest(.nothingHere(port: 8787))); #expect(flow.localSetup == .failed("No."))
    // Once the Mac answers, the offer is gone; going back to where bots run forgets all of it.
    let mac = HerdrServer(id: "default", name: "This Mac", kind: .local, address: HerdrServer.loopback(port: 8787))
    let one = HerdrProgram(template: "starter-one", name: "One", takesModel: false, models: [])
    flow.apply(.herdrTest(.connected(server: mac, key: nil, offer: HerdrOffer(programs: [one]))))
    #expect(flow.localSetup == nil && flow.herdrReady)
    flow.apply(.aiCheck(HerdrAICheck(template: "starter-one", name: "One")))
    #expect(flow.aiChecking && !flow.aiNeedsAnswer)
    flow.apply(.aiCheck(HerdrAICheck(template: "starter-one", name: "One", state: .asks(screen: "Trust?", agent: .init(address: "t1", createdMs: 7)))))
    #expect(flow.aiChecks.count == 1 && flow.aiNeedsAnswer && !flow.aiChecking && flow.herdrReady, "a question does not hold the wizard")
    flow.apply(.back)
    #expect(flow.step == .welcome && flow.aiChecks.isEmpty && flow.localSetup == nil && flow.localReport == nil)
    #expect(HerdrLocalSetup.line(for: HerdrLocalFailure(kind: "core_signature", message: "Not signed by Herdr.")) == "Not signed by Herdr.")
    #expect(HerdrLocalSetup.line(for: WorkspaceRelease.Failure.unsigned) == WorkspaceRelease.Failure.unsigned.localizedDescription)
    #expect(HerdrLocalSetup.line(for: WorkspaceRelease.Failure.unreachable).contains("could not finish downloading"))
    #expect(HerdrLocalSetup.line(for: WorkspaceRelease.Failure.noProgram("x86_64-macos")).contains("not published for this kind of Mac"))
}

@Test func anAIsQuestionIsShownAsItsTerminalShowsItAndOpenedInTerminal() {
    let screen = """

        ────────────────────────────────────────
         Accessing workspace:

         /Users/ada/swarmhub-agents

        │ Quick safety check: Is this a project you trust? │

         ❯ No, exit
           Yes, I trust this folder
        ════════════════════
        """
    #expect(HerdrAICheck.question(from: screen) == "Accessing workspace:\n/Users/ada/swarmhub-agents\nQuick safety check: Is this a project you trust?\n❯ No, exit\nYes, I trust this folder")
    #expect(HerdrAICheck.question(from: "one\ntwo\nthree", lines: 2) == "two\nthree" && HerdrAICheck.question(from: " \n──\n").isEmpty)
    #expect(HerdrAICheck.agentName(template: "swarmhub-claude") == "setup-swarmhub-claude" && HerdrAICheck.agentName(template: String(repeating: "a", count: 40)).count == 32)
    let script = AppStore.terminalScript(core: "/Users/ada/.local/bin/hc", address: "t7", name: "One", environment: ["HC_SESSION": "check", "PATH": "/bin", "XDG_STATE_HOME": "/tmp/it's"])
    #expect(script.hasPrefix("#!/bin/sh\n") && script.hasSuffix("exec '/Users/ada/.local/bin/hc' attach 't7'\n"))
    #expect(script.contains("export HC_SESSION='check'\n") && script.contains("export XDG_STATE_HOME='/tmp/it'\"'\"'s'\n") && !script.contains("PATH"))
}

/// A server that starts an agent ahead of its first message: the check starts the AI with no task and reads whether
/// it gets ready. `ready`: what the server says about the started agent each time it is asked.
private func checkClient(ready: [Bool], live: Bool = true, screen: String = " Trust this folder?\n") -> (HerdrClient, LockedTrace) {
    let trace = LockedTrace(), looked = LockedTrace()
    let served = MockHTTPProtocol.serve { request in
        let path = request.url?.path ?? "", method = request.httpMethod ?? "GET"
        trace.add("\(method) \(path)")
        let template: [String: Any] = ["name": "starter-one", "description": "", "error": NSNull(), "runtime": ["harness": "Program One"]]
        func agent(_ ready: Bool) -> [String: Any] {
            ["address": "t1", "name": "setup-starter-one", "state": live ? "live" : "finished", "created_ms": 7, "template": "starter-one", "status": NSNull(), "ready": ready, "warm": true]
        }
        if method == "POST", path == "/api/agents" { return (201, agent(false)) }
        if path == "/api/workspace" {
            let started = trace.read().contains("POST /api/agents")
            // The first look is the one before the start; each later one moves through `ready`.
            if started { looked.add("looked") }
            let index = min(max(looked.read().count - 1, 0), ready.count - 1)
            return (200, ["core": "core-1", "version": "0.1.21", "templates": [template], "agents": started ? [agent(ready[index])] : []])
        }
        if path == "/api/profiles" { return (200, [Any]()) }
        if path.hasSuffix("/output") { return (200, ["text": screen]) }
        if path.hasSuffix("/end") { return (200, [String: Any]()) }
        return (404, ["error": "not found"])
    }
    var client = HerdrClient(baseURL: URL(string: "http://\(served.host)")!, token: "t"); client.session = served.session
    return (client, trace)
}

@Suite struct HerdrAICheckTests {
    @Test func anAIThatGetsReadyIsEndedAgainAndOneThatAsksIsLeftRunning() async {
        let (ready, readyTrace) = checkClient(ready: [false, true])
        let first = await ready.firstRunCheck(template: "starter-one", wait: .seconds(5), every: .milliseconds(10))
        #expect(first == .ready, "\(first) \(readyTrace.read())")
        #expect(readyTrace.read().contains("POST /api/agents") && readyTrace.read().contains("POST /api/agents/t1/7/end"), "nothing is left running")

        let (asks, asksTrace) = checkClient(ready: [false])
        let state = await asks.firstRunCheck(template: "starter-one", wait: .milliseconds(60), every: .milliseconds(10))
        #expect(state == .asks(screen: "Trust this folder?", agent: .init(address: "t1", createdMs: 7)))
        #expect(!asksTrace.read().contains("POST /api/agents/t1/7/end"), "its terminal stays, so the person can answer there")

        let (gone, _) = checkClient(ready: [false], live: false)
        if case .failed = await gone.firstRunCheck(template: "starter-one", wait: .seconds(1), every: .milliseconds(10)) {} else { Issue.record("an AI that ended is not ready") }
    }
}

/// The screens of "This Mac" render, each differently, and showing them writes nothing.
@MainActor @Test func thisMacsScreensRender() async throws {
    let store = SetupPreview.makeStore(); store.isSetupPreview = false
    let updater = AppUpdater(environment: ["SWARMHUB_DISABLE_UPDATES": "1"])
    let flows = HeadlessHerdrShots.localFlows(thisMac: store.herdrServers[0])
    #expect(flows.count == HeadlessHerdrShots.thisMac.count - 1 && flows.allSatisfy { $0.step == .herdr })
    var sizes: [Int] = []
    for index in [0, 2, 6, 8] {
        let data = try #require(await HeadlessSetup.png(SetupView(preset: flows[index]), store: store, updater: updater, size: HeadlessSetup.size))
        #expect(data.count > 4_000, "\(HeadlessHerdrShots.thisMac[index]) looks blank"); sizes.append(data.count)
    }
    #expect(Set(sizes).count == sizes.count)
    #expect(store.bots.isEmpty && store.defaults.string(forKey: HerdrServer.listKey) == nil)
}

/// This Mac's usual port can already lead to another server (a forward answers there). Setup then takes the port this
/// Mac's own service is on, or the next one nothing uses, and never asks for the key of what answers.
@Test @MainActor func thisMacTakesAnotherPortWhenItsUsualOneLeadsElsewhere() async {
    let answering: @Sendable (Int) async -> Bool = { $0 == 8787 }, silent: @Sendable (Int) async -> Bool = { _ in false }
    let next: @Sendable (Int) -> Int? = { HerdrTunnels.freePort(after: $0) { $0 != 8788 } }
    #expect(await AppStore.thisMacPort(wanted: 8787, ownPort: nil, hasKey: false, answers: answering, free: next) == 8789, "something else answers and this Mac has no key for it: the next port nothing uses")
    #expect(await AppStore.thisMacPort(wanted: 8787, ownPort: nil, hasKey: false, answers: silent, free: next) == nil, "nothing answers: the usual port is free to set up on")
    #expect(await AppStore.thisMacPort(wanted: 8787, ownPort: nil, hasKey: true, answers: answering, free: next) == nil, "a key is here: what answers is tried with it")
    #expect(await AppStore.thisMacPort(wanted: 8787, ownPort: 8790, hasKey: true, answers: answering, free: next) == 8790, "this Mac's own service says where it is")
    #expect(await AppStore.thisMacPort(wanted: 8790, ownPort: 8790, hasKey: true, answers: answering, free: next) == nil)
    #expect(HerdrTunnels.freePort(after: 65535) == nil && HerdrTunnels.freePort(after: 8787) { _ in false } == nil)
    #expect(!HerdrTunnels.isFree(port: 0) && !HerdrTunnels.isFree(port: 70000))
    #expect(WizardCopy.portMoved(from: 8787, to: 8788) == "Port 8787 on this Mac is already in use, so SwarmHub uses port 8788 here.")
}

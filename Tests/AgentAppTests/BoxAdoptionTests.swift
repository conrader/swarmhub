import Foundation
import Testing
@testable import AgentApp

// P35 pure parts: the recipes in the manager text (and their shell test under /bin/sh and /bin/dash), the swarmhub
// ops they report, the refusal rules, the discovery sort, the setup window's scan states and the copy. Synthetic only.

private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

/// `Tests/Scripts/box-adopt-test.sh` under each shell present: the three recipes cut out of recipes/box.md, run in a
/// temp HOME with a synthetic ~/.hermes; every case must pass.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func boxAdoptShellTestPasses(_ shell: String) throws {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = [repoRoot.appending(path: "Tests/Scripts/box-adopt-test.sh").path, repoRoot.appending(path: "Resources/BotManager/recipes/box.md").path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "BOX_SH": shell]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(shell):\n\(output)")
    #expect(output.contains("box-adopt tests under \(shell): 9 passed, 0 failed"), "\(output)")
    #expect(!output.contains("FAIL"), "\(output)")
}

/// The shell test's expected keys are the ones SwarmHub derives.
@Test func shellTestVectorsAreTheDerivedKeys() throws {
    let script = try String(contentsOf: repoRoot.appending(path: "Tests/Scripts/box-adopt-test.sh"), encoding: .utf8)
    for name in ["cfo", "lowcost"] {
        #expect(script.contains("KEY_\(name.uppercased())=\(BotManagerText.derivedKey(managerKey: "boss-key", botName: name))"))
    }
}

// MARK: Recipes and instructions

@Test func boxRecipeFileCarriesTheThreeRecipes() throws {
    let template = try #require(BotManagerText.recipe(.box))
    let list = try #require(BoxAdoption.recipe(BoxAdoption.listMarker, in: template))
    let adopt = try #require(BoxAdoption.recipe(BoxAdoption.adoptMarker, in: template))
    let restore = try #require(BoxAdoption.recipe(BoxAdoption.restoreMarker, in: template))
    #expect(list.contains(#"printf '{"op":"bots","list":[%s]}\n'"#) && list.contains("default $(ls profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')"))
    #expect(!list.contains("hermes profile") && !list.contains("hermes -p"), "files only: no Hermes CLI start")
    #expect(adopt.contains("cp -p \"$E\" \"$N/$B\" && chmod 600") && adopt.contains("B=.env.swarmhub-bak-$S") && adopt.contains("case $N in default|{{MANAGER}}|"))
    #expect(adopt.contains(#"swarmhub-bot-key:v1:$N"#) && adopt.contains(#"printf '{"op":"bots_adopted","results":[%s]}\n'"#))
    #expect(restore.contains("case $N in default|{{MANAGER}}") && restore.contains(#"{"op":"key_restored""#))
    for recipe in [list, adopt, restore] { #expect(!recipe.contains("cat .env") && !recipe.contains("echo \"$K\"") && !recipe.contains("echo $MK")) }
}

@Test func instructionsAreFilledAndRefuseWhatTheyMust() throws {
    let template = try #require(BotManagerText.recipe(.box))
    let list = try #require(BoxAdoption.listInstructions(template: template, managerProfile: "grok-jarvis"))
    #expect(!list.contains("{{") && list.contains("Reading needs no confirmation") && list.contains("````sh\n( cd ~/.hermes"))
    let adopt = try #require(BoxAdoption.adoptInstructions(template: template, managerProfile: "grok-jarvis", names: ["cfo", "lowcost"]))
    #expect(adopt.contains("for N in cfo lowcost; do") && adopt.contains("~/.hermes/profiles/grok-jarvis/.env") && adopt.contains("default|grok-jarvis|"))
    #expect(adopt.contains("That press is his yes") && !adopt.contains("<names>") && !adopt.contains("{{"))
    #expect(BoxAdoption.adoptInstructions(template: template, managerProfile: "grok-jarvis", names: []) == nil)
    #expect(BoxAdoption.adoptInstructions(template: template, managerProfile: "grok-jarvis", names: ["cfo; rm -rf ~"]) == nil)
    let restore = try #require(BoxAdoption.restoreInstructions(template: template, managerProfile: "default", name: "cfo", backup: ".env.swarmhub-bak-20261015T101500Z"))
    #expect(restore.contains("N=cfo; B=.env.swarmhub-bak-20261015T101500Z;") && restore.contains("case $N in default|default|"))
    #expect(BoxAdoption.restoreInstructions(template: template, managerProfile: "default", name: "cfo", backup: "")?.contains("N=cfo; B=;") == true)
    #expect(BoxAdoption.restoreInstructions(template: template, managerProfile: "default", name: "cfo", backup: "../../.env") == nil)
    #expect(BoxAdoption.listInstructions(template: "no recipes here", managerProfile: "default") == nil)
}

// MARK: Ops

@Test func listAdoptAndRestoreOpsParse() {
    func ops(_ json: String) -> [SwarmhubOp]? { SwarmhubBlock.ops(in: "Done.\n```swarmhub\n\(json)\n```") }
    #expect(ops(#"{"op":"bots","list":[{"name":"default","has_key":true},{"name":"lowcost","has_key":false},{"name":"Bad Name","has_key":true}]}"#)
            == [.bots([.init(name: "default", description: "", hasKey: true), .init(name: "lowcost", description: "", hasKey: false)])])
    #expect(ops(#"{"op":"bots","list":[{"name":"cfo","description":"CFO"}]}"#) == [.bots([.init(name: "cfo", description: "CFO")])], "P26 lists keep working")
    let adopted = ops(#"{"op":"bots_adopted","results":[{"name":"cfo","ok":true,"backup":".env.swarmhub-bak-20261015T101500Z"},{"name":"lowcost","ok":true,"backup":""},"#
                      + #"{"name":"krytyk","ok":false,"backup":""},{"name":"wingman","ok":true,"backup":"../../x"},{"name":"sekretarz"},{"name":"../x","ok":true}]}"#)
    #expect(adopted == [.botsAdopted([.init(name: "cfo", ok: true, backup: ".env.swarmhub-bak-20261015T101500Z"), .init(name: "lowcost", ok: true, backup: nil),
                                      .init(name: "krytyk", ok: false, backup: nil), .init(name: "wingman", ok: false, backup: nil),
                                      .init(name: "sekretarz", ok: false, backup: nil)])])
    #expect(ops(#"{"op":"key_restored","name":"cfo","ok":true}"#) == [.keyRestored(name: "cfo", ok: true)])
    #expect(ops(#"{"op":"key_restored","name":"cfo"}"#) == [.keyRestored(name: "cfo", ok: false)])
    #expect(ops(#"{"op":"key_restored","name":"../cfo","ok":true}"#) == [])
}

// MARK: Rules

@Test func adoptionNeverReKeysDefaultTheManagerTypedOrBoundProfiles() {
    let names = ["cfo", "default", "grok-jarvis", "mine", "coder", "lowcost", "cfo", "Bad Name", "../x", ""]
    #expect(BoxAdoption.adoptable(names, managerProfile: "grok-jarvis", typed: ["mine"], bound: ["coder"]) == ["cfo", "lowcost"])
    #expect(BoxAdoption.adoptable(["default"], managerProfile: "boss", typed: [], bound: []) == [])
}

@Test func discoverySortsTheList() {
    let listed: [SwarmhubOp.ListedBot] = ["default", "grok-jarvis", "cfo", "mine", "coder", "lowcost"].map { .init(name: $0, description: "", hasKey: $0 != "lowcost") }
    let sorted = BoxAdoption.sort(listed, managerProfile: "grok-jarvis", typed: ["mine"], bound: ["coder"])
    #expect(sorted.needsKey.map(\.name) == ["default", "mine"] && sorted.candidates.map(\.name) == ["cfo", "lowcost"])
    #expect(BoxAdoption.sort(listed, managerProfile: "default", typed: [], bound: []).needsKey.isEmpty, "the manager itself is not listed")
}

// MARK: Setup window

@MainActor @Test func setupScanStatesOnS4() {
    let box = BoxAddress.url("my-box.example.com")!
    var flow = SetupFlow(prefill: .init(startAtAddress: true)); flow.input.address = "my-box.example.com"; flow.input.key = "k"
    let result = HeadlessSetup.sampleResult(baseURL: box)
    flow.apply(.test(result)); flow.preselect(alreadyAdded: [])
    #expect(flow.step == .choose && flow.box == .looking && flow.boxScan == nil)
    let scan = SetupBoxScan(managerName: "Hermes", managerProfile: "default", managerIsNew: true, listed: 23, derived: ["knowledge-guide"],
                            adoptable: ["cfo", "lowcost"], needsKey: [])
    flow.apply(.boxScanned(scan))
    #expect(flow.boxScan == scan && flow.choices.map(\.id) == ["default", "research", "writer", "knowledge-guide"])
    #expect(flow.chosen == ["default", "research", "writer", "knowledge-guide"] && flow.adoptOn)
    flow.apply(.boxScanned(nil))
    #expect(flow.boxScan == scan, "a late second answer does not replace the first")
    var failed = SetupFlow(prefill: .init(startAtAddress: true)); failed.apply(.test(result)); failed.apply(.boxScanned(nil))
    #expect(failed.box == .failed && failed.choices.count == 3)
    failed.apply(.test(.init(outcome: .unreachable, baseURL: box)))
    #expect(failed.box == .idle)
}

@Test func p35CopyReadsAsTheBriefSays() {
    #expect(BoxCopy.found(23) == "Found 23 bots on this box" && BoxCopy.found(1) == "Found 1 bot on this box")
    #expect(BoxCopy.managerLine("Ermes") == "Ermes will set up the other bots on this box.")
    #expect(BoxCopy.sectionTitle(place: nil) == "On this box · not connected" && BoxCopy.sectionTitle(place: "box.example") == "On box.example · not connected")
    #expect(BoxCopy.adopted(added: ["cfo"], failed: ["lowcost"]) == "Connected Cfo. Couldn’t connect Lowcost; they are listed under “not connected”.")
    #expect(BoxCopy.scanned(BoxScan(listed: 23, added: ["knowledge-guide"], adoptable: ["cfo"], needsKey: ["default"]))
            == "Found 23 bots; added Knowledge Guide; 1 to connect; 1 need their own key.")
    #expect(BoxCopy.mainBotWhy.split(separator: ".").count <= 3 && !BoxCopy.mainBotWhy.contains("\n"), "D4: the reason in one line")
}

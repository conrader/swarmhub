import Foundation
import Testing
@testable import AgentApp

// 0.6.4 speed: batched all-bots turns, skills copied from a profile that holds them (verified on the box), one peer call
// per batch that stops enabling after Hermes PM blocks it. The shell cases run the real generated commands. Synthetic only.

private final class SpeedClock { var date = Date(timeIntervalSince1970: 2_000_000_000) }

@MainActor private func speedStore(_ names: [String]) -> (AppStore, Bot, [Bot]) {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in MockBackend() },
                         keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text"
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.canManageBots = true
    for skill in store.skillLibrary where AppStore.messagingSkills.contains(skill.name) { jarvis.installedSkills[skill.name] = skill.version.description }
    let others = names.map { Bot(name: $0, backend: .hermes, hermesProfile: "grok-" + $0.lowercased()) }
    store.bots = [jarvis] + others; store.selectedBot = jarvis
    return (store, jarvis, others)
}

private func shell(_ script: String, home: URL, path: String = "/usr/bin:/bin") async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = ["PATH": path, "HOME": home.path, "TMPDIR": FileManager.default.temporaryDirectory.path]
    return try await runToEnd(process)
}

private func scratchHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "speed-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
}

private func onBox(_ path: String, home: URL) -> URL { home.appending(path: String(path.dropFirst(2))) }

@Test @MainActor func batchesAreBoundedAndADevModeBotGoesAlone() throws {
    let (store, jarvis, others) = speedStore((1...12).map { "Bot\($0)" })
    others[3].skillDevMode = true
    let gaps = store.messagingSkillGaps(manager: jarvis)
    #expect(gaps.map(\.bot.id) == others.map(\.id), "the manager holds both skills at this version and is never sent")
    var queue = gaps, batches: [[String]] = []
    while !queue.isEmpty {
        let next = try store.nextAllBotsBatch(queue, manager: jarvis)
        #expect(AppStore.encodedInstructionsSize(next.instructions) <= SkillInstallPayloadError.instructionsByteBudget)
        #expect(installProfiles(next.instructions) == next.gaps.map { store.profile(of: $0.bot) })
        batches.append(next.gaps.map(\.bot.name)); queue.removeFirst(next.gaps.count)
    }
    #expect(batches == [["Bot1", "Bot2", "Bot3"], ["Bot4"], ["Bot5", "Bot6", "Bot7", "Bot8", "Bot9", "Bot10", "Bot11", "Bot12"]])
    store.allBotsBatchLimit = 2
    #expect(try store.nextAllBotsBatch(Array(gaps.suffix(5)), manager: jarvis).gaps.count == 2)
    store.allBotsSkillSolo[jarvis.id] = [others[0].id]
    #expect(try store.nextAllBotsBatch(gaps, manager: jarvis).gaps.count == 1, "a refused batch's bot goes alone")
}

@Test @MainActor func copySourcesPreferAHolderAndNeverServeARetryOrDevMode() throws {
    let (store, jarvis, others) = speedStore(["Infra", "Reactor"])
    let gaps = store.messagingSkillGaps(manager: jarvis)
    #expect(store.skillSources(for: gaps[1], in: gaps).values.allSatisfy { $0.profile == "grok-jarvis" })
    // Without a holder, a later bot copies from the first one of its batch, which writes the files out.
    jarvis.installedSkills = [:]
    let fresh = store.messagingSkillGaps(manager: jarvis).filter { $0.bot.id != jarvis.id }
    #expect(store.skillSources(for: fresh[0], in: fresh).isEmpty)
    #expect(Set(store.skillSources(for: fresh[1], in: fresh).values.map(\.profile)) == ["grok-infra"])
    let text = try #require(try store.allBotsSkillInstructions(fresh))
    #expect(text.contains("cat > ~/.hermes/profiles/grok-infra/skills/swarmhub/swarmhub-messages/scripts/bot-msg <<'SWARMHUB_EOF'"))
    #expect(!text.contains("cat > ~/.hermes/profiles/grok-reactor/skills/") && text.contains("python3 - '~/.hermes/profiles/grok-infra/skills/swarmhub/swarmhub-messages'"))
    // A skill whose last install failed is written out in full on its retry; a dev-mode bot never copies.
    let messages = try #require(store.skillLibrary.first { $0.name == "swarmhub-messages" })
    others[1].skillInstallFailures[messages.name] = SkillInstallFailure(version: messages.version.description, variant: nil, count: 1,
                                                                        lastAt: .distantPast, reason: "Refused.")
    let retry = store.messagingSkillGaps(manager: jarvis).filter { $0.bot.id != jarvis.id }
    #expect(store.skillSources(for: retry[1], in: retry)[messages.name] == nil && store.skillSources(for: retry[1], in: retry)["swarmhub-feedback"] != nil)
    others[1].skillDevMode = true
    #expect(store.skillSources(for: retry[1], in: retry).isEmpty)
}

@Test @MainActor func aSkillCopiedFromAHolderLandsByteForByteAndAStaleSourceWritesNothing() async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let (store, jarvis, others) = speedStore(["Infra"])
    let home = try scratchHome(); defer { try? FileManager.default.removeItem(at: home) }
    let skills = store.skillLibrary.filter { AppStore.messagingSkills.contains($0.name) }
    for skill in skills {
        let folder = SkillLibrary.installPath(skill.name, profile: "grok-jarvis")
        for file in try #require(store.renderedSkillFiles(skill, profile: "grok-jarvis", codingOrder: store.codingOrder(for: jarvis))) {
            try write(SkillSync.written(file.content), to: onBox("\(folder)/\(file.path)", home: home), executable: file.isExecutable)
        }
    }
    let sources = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, AppStore.SkillSource(profile: "grok-jarvis", codingOrder: store.codingOrder(for: jarvis))) })
    let install = try #require(try store.skillInstallCommands(skills, profile: "grok-infra", codingOrder: store.codingOrder(for: others[0]), peerInline: false, sources: sources))
    let script = install.commands.joined(separator: "\n")
    // No file written out, and no peer call inline (peer-runtime.py itself is one of the copied files).
    #expect(!script.contains("SWARMHUB_EOF") && !script.contains("SWARMHUB_PEER_ENABLE") && !script.contains("peer-runtime.py start"))
    let run = try await shell(script, home: home)
    #expect(run.status == 0, "\(run.output)")
    for skill in skills {
        let folder = SkillLibrary.installPath(skill.name, profile: "grok-infra")
        for file in try #require(store.renderedSkillFiles(skill, profile: "grok-infra", codingOrder: store.codingOrder(for: others[0]))) {
            let landed = try String(contentsOf: onBox("\(folder)/\(file.path)", home: home), encoding: .utf8)
            #expect(landed == SkillSync.written(file.content), "\(skill.name)/\(file.path)")
        }
    }
    // A source that changed since (or was never this version) fails closed: nothing written, the refusal printed.
    let target = onBox(SkillLibrary.installPath("swarmhub-messages", profile: "grok-infra"), home: home)
    try FileManager.default.removeItem(at: target)
    let bot = onBox(SkillLibrary.installPath("swarmhub-messages", profile: "grok-jarvis") + "/scripts/bot-msg", home: home)
    try write(try String(contentsOf: bot, encoding: .utf8) + "# edited\n", to: bot, executable: true)
    let stale = try await shell(script, home: home)
    #expect(stale.output.contains("\(SkillSync.failure) ~/.hermes/profiles/grok-infra/skills/swarmhub/swarmhub-messages"), "\(stale.output)")
    #expect(!FileManager.default.fileExists(atPath: target.appending(path: "SKILL.md").path))
}

@Test func aProfileNameThatAlsoAppearsInTheTextIsNotCopied() {
    let expected = [SkillFile(path: "SKILL.md", content: "bot b, default reply\n")]
    let source = [SkillFile(path: "SKILL.md", content: "bot a, default reply\n")]
    #expect(SkillSync.plan(expected: expected, source: source, sourceFolder: "~/s", folder: "~/d", substitutions: [("~/s", "~/d"), ("a", "b")]) == nil,
            "swapping every \"a\" also rewrites \"default\" and \"reply\": the file is written out instead")
    #expect(SkillSync.plan(expected: expected, source: source, sourceFolder: "~/s", folder: "~/d", substitutions: [("bot a", "bot b")])?.names == ["SKILL.md*"])
    #expect(SkillSync.plan(expected: expected, source: source, sourceFolder: "~/s'", folder: "~/d", substitutions: [("bot a", "bot b")]) == nil)
}

@Test(arguments: [false, true]) @MainActor func onePeerCallStopsEnablingAfterTheFirstPMBlock(skipEnable: Bool) async throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let home = try scratchHome(); defer { try? FileManager.default.removeItem(at: home) }
    let log = home.appending(path: "calls.log").path
    let profiles = ["grok-a", "grok-b", "grok-c"]
    for profile in profiles {
        let script = onBox(SkillLibrary.installPath("swarmhub-messages", profile: profile) + "/scripts/peer-runtime.py", home: home)
        try write("import sys\nopen('\(log)', 'a').write('runtime ' + ' '.join(sys.argv[1:]) + '\\n')\n", to: script)
    }
    try write("""
    #!/bin/sh
    echo "hermes $*" >> '\(log)'
    case "$4" in
    enable) echo "PermissionError: [Errno 13] Permission denied: '/opt/hermes-core/workspace'"; exit 1 ;;
    *) echo "swarmhub-peer  disabled" ;;
    esac
    """ + "\n", to: home.appending(path: "bin/hermes"), executable: true)
    let command = PeerPluginEnablement.command(profiles: profiles, skipEnable: skipEnable)
    let run = try await shell(command, home: home, path: home.appending(path: "bin").path + ":/usr/bin:/bin")
    #expect(run.status == 0, "\(run.output)")
    let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(calls.filter { $0.hasPrefix("runtime install") }.count == 3 && calls.filter { $0 == "runtime start" }.count == 3)
    #expect(calls.filter { $0.hasPrefix("hermes") } == (skipEnable ? [] : ["hermes -p grok-a plugins enable swarmhub-peer", "hermes -p grok-a plugins list"]),
            "one Hermes CLI attempt at most, never one per profile")
    let hermes = HermesBackend(baseURL: URL(string: "http://127.0.0.1")!, apiKey: "")
    var call = PeerPluginEnablement.Call()
    call.consume(hermes.nativeTool("tool.started", ["tool_name": "terminal", "tool_call_id": "peer", "args": ["command": command]]), profiles: Set(profiles), batch: profiles)
    call.consume(hermes.nativeTool("tool.completed", ["tool_name": "terminal", "tool_call_id": "peer", "result": ["exit_code": 0, "output": run.output]]),
                 profiles: Set(profiles), batch: profiles)
    #expect(Set(call.receipts.keys) == Set(profiles) && call.receipts.values.allSatisfy { $0.result.status == .peerEnableBlocked })
    #expect(call.receipts["grok-a"]?.skipped == skipEnable && call.receipts["grok-b"]?.skipped == true && call.receipts["grok-c"]?.skipped == true)
}

@Test @MainActor func aPMBlockSkipsEnableInBatchesForTwelveHoursButNeverForOneBot() throws {
    let (store, jarvis, others) = speedStore(["Infra", "Reactor"])
    let clock = SpeedClock(); store.now = { clock.date }
    let messages = try #require(store.skillLibrary.first { $0.name == "swarmhub-messages" })
    store.noteSkillInstallChecks([(others[0], [messages])], manager: jarvis)
    let blocked = PeerPluginEnablement.Receipt(profile: "grok-infra", enable_exit: 1, list_exit: 0, enable_output: "PermissionError", list_output: "")
    store.peerEnableCalls[jarvis.id] = PeerPluginEnablement.Call(receipts: ["grok-infra": blocked])
    let op = #"{"op":"skills_installed","bot":"grok-infra","skills":[{"name":"swarmhub-messages","version":"\#(messages.version)"}]}"#
    store.finishSkillInstallChecks(manager: jarvis, reply: ChatMessage(role: .assistant, content: "Done.\n```swarmhub\n\(op)\n```"), end: .completed)
    #expect(store.skillInstallResults[others[0].id]?.status == .peerEnableBlocked && store.peerEnableKnownBlocked(on: store.connection(of: jarvis)))
    let gaps = store.messagingSkillGaps(manager: jarvis)
    // Infra now has the messaging skill and only lacks feedback: the peer call covers the bots installing messages.
    let peers = gaps.filter { $0.installable.contains { $0.name == messages.name } }.map { store.profile(of: $0.bot) }
    #expect(gaps.count == 2 && peers == ["grok-reactor"])
    let batch = try #require(try store.allBotsSkillInstructions(gaps))
    #expect(batch.contains(PeerPluginEnablement.command(profiles: peers, skipEnable: true)))
    // One bot's own Install still tries, so the box operator's fix shows at once.
    let single = try #require(try store.skillInstallInstructions([messages], profile: "grok-reactor", botName: "Reactor"))
    #expect(single.contains(PeerPluginEnablement.command(profile: "grok-reactor")))
    clock.date += AppStore.peerBlockWindow
    #expect(!store.peerEnableKnownBlocked(on: store.connection(of: jarvis)))
    #expect(try #require(try store.allBotsSkillInstructions(gaps)).contains(PeerPluginEnablement.command(profile: "grok-reactor")))
    // A verified enable ends the window early; a skipped one never extends it.
    store.notePeerEnableBlocked(true, on: store.connection(of: jarvis))
    store.noteSkillInstallChecks([(others[1], [messages])], manager: jarvis)
    let enabled = PeerPluginEnablement.Receipt(profile: "grok-reactor", enable_exit: 0, list_exit: 0, enable_output: "", list_output: "swarmhub-peer enabled")
    store.peerEnableCalls[jarvis.id] = PeerPluginEnablement.Call(receipts: ["grok-reactor": enabled])
    store.finishSkillInstallChecks(manager: jarvis, reply: ChatMessage(role: .assistant, content: "Done.\n```swarmhub\n\(op.replacingOccurrences(of: "grok-infra", with: "grok-reactor"))\n```"), end: .completed)
    #expect(!store.peerEnableKnownBlocked(on: store.connection(of: jarvis)))
}

@Test func theManagersOwnWordingOfAPermissionBlockCounts() {
    #expect(PeerPluginEnablement.reportedBlock("Installed SwarmHub Messages 1.4.7; peer-plugin enablement is blocked by permissions and needs the box operator."))
    #expect(!PeerPluginEnablement.reportedBlock("Skills installed; the file write was blocked by permissions."), "a peer plugin must be named")
}

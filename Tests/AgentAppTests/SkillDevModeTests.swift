import Foundation
import Testing
@testable import AgentApp

// Skill dev mode (per bot, Mac) on the legacy shell installer: a skill the bot modified on its box is kept, shown as
// modified locally and never a failure; unmodified skills still update; Reset to bundled replaces one; off is exactly the
// old installer. Synthetic servers only; the box side (the guard script's bytes, the updater) runs in
// Tests/Updater/test_devmode.py and test_devmode_guard.py.

private let devManager = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!,
    template: "---\nname: swarmhub-manager\ndescription: \"Use when. Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")
private let devFeedback = BundledSkill(name: "swarmhub-feedback", version: SkillVersion("1.0.0")!,
    template: "---\nname: swarmhub-feedback\ndescription: \"Report. Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.0.0\n---\n\nFile reports.\n")
private let devManagerFolder = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-manager"
private let devFeedbackFolder = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-feedback"
private let devManagerRow = #"{"name":"swarmhub-manager","version":"1.2.0"}"#
private let devFeedbackRow = #"{"name":"swarmhub-feedback","version":"1.0.0"}"#
private let keptFeedback = "SWARMHUB_DEV_KEPT:grok-jarvis/swarmhub-feedback\n"

private final class DevClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

/// Jarvis manages itself on `grok-jarvis` (both skills meant for it). Each chat turn runs one terminal step whose result
/// is the next of `outputs` (nil or none: no step), then answers with the next of `replies`.
@MainActor private func devStore(replies: [String], outputs: [String?] = []) -> (AppStore, Bot, String, DevClock) {
    let counter = LockedTrace()
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let turn = counter.read().count - 1
            var events: [(String, [String: Any])] = []
            if turn < outputs.count, let output = outputs[turn] {
                events += [("tool.started", ["tool_name": "terminal", "tool_call_id": "install-\(turn)", "args": ["command": "install"]]),
                           ("tool.completed", ["tool_name": "terminal", "tool_call_id": "install-\(turn)", "result": ["output": output, "exit_code": 0]])]
            }
            return .sse(events + [("assistant.delta", ["delta": replies[min(turn, replies.count - 1)]]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        return .json(500, ["error": ["message": "Failed to enumerate skills"]])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k"]), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text for {{MANAGER}} ({{MANAGER_ENV}})"
    store.skillLibraryOverride = [devFeedback, devManager]
    let clock = DevClock(); store.now = { clock.date }
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, host, clock)
}

private func devTurns(_ host: String) -> [String] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["instructions"] as? String ?? "" }
}

private func devInstalled(_ rows: String) -> String {
    "Done.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[\(rows)]}\n```"
}

// MARK: Dev mode on

@Test @MainActor func devModeKeepsALocallyModifiedSkillWithoutAFailureOrBackoff() async throws {
    let (store, jarvis, host, _) = devStore(replies: [devInstalled(devManagerRow + "," + devFeedbackRow)], outputs: [keptFeedback])
    store.setSkillDevMode(true, for: jarvis)
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-manager"] != nil }
    let sent = try #require(devTurns(host).first)
    #expect(sent.contains(SkillDevMode.functionHead) && sent.contains("swarmhub_dev check grok-jarvis swarmhub-feedback "))
    #expect(sent.contains("swarmhub_dev check grok-jarvis swarmhub-manager ") && sent.contains("Skill dev mode is on"))
    #expect(!sent.contains("SWARMHUB_DEV_KEPT:"), "the command never carries a marker the output could be confused with")
    // The manager skill was SwarmHub's and updated; the feedback skill is the bot's own now.
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"], "the block was written before the box kept feedback")
    #expect(jarvis.skillsModifiedLocally == ["swarmhub-feedback"] && store.isModifiedLocally(devFeedback, for: jarvis))
    #expect(jarvis.skillInstallFailures.isEmpty && store.skillInstallFailure(devFeedback, for: jarvis) == nil)
    // Never offered or sent again while dev mode is on: no banner, no loop.
    #expect(store.skillBanner(for: jarvis) == nil && store.skillsToInstall(for: jarvis).isEmpty && !store.installSkills(for: jarvis))
    #expect(store.messagingSkillGaps(manager: jarvis).isEmpty, "not an all-bots gap either")
    #expect(devTurns(host).count == 1)
}

@Test @MainActor func devModeStillUpdatesUnmodifiedSkills() async throws {
    let (store, jarvis, host, _) = devStore(replies: [devInstalled(devFeedbackRow + "," + devManagerRow)], outputs: [""])
    store.setSkillDevMode(true, for: jarvis)
    jarvis.installedSkills = ["swarmhub-feedback": "0.9.0", "swarmhub-manager": "1.1.0"]
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-feedback"] == "1.0.0" }
    #expect(jarvis.installedSkills["swarmhub-manager"] == "1.2.0" && jarvis.skillsModifiedLocally.isEmpty)
    #expect(jarvis.skillInstallFailures.isEmpty)
    let sent = try #require(devTurns(host).first)
    #expect(sent.contains("swarmhub_dev record grok-jarvis swarmhub-feedback ;;"))
}

@Test @MainActor func aSlashEscapedMarkerFromAnObjectResultStillCounts() {
    #expect(SkillDevMode.outcomes(in: #"{"output":"SWARMHUB_DEV_KEPT:grok-jarvis\/swarmhub-feedback\nSWARMHUB_DEV_FAILED:p_2/swarmhub-coding"}"#).map { $0.key }
            == ["grok-jarvis/swarmhub-feedback", "p_2/swarmhub-coding"])
    #expect(SkillDevMode.outcomes(in: "swarmhub_dev check grok-jarvis swarmhub-feedback; echo 'SWARMHUB_DEV_''KEPT:grok-jarvis/x'").isEmpty)
}

@Test @MainActor func aFailedGuardIsAFailureWhateverTheBlockSays() async throws {
    let failed = "SWARMHUB_DEV_FAILED:grok-jarvis/swarmhub-feedback\n"
    let (store, jarvis, _, _) = devStore(replies: [devInstalled(devManagerRow + "," + devFeedbackRow)], outputs: [failed])
    store.setSkillDevMode(true, for: jarvis)
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && !jarvis.skillInstallFailures.isEmpty }
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"] && jarvis.skillsModifiedLocally.isEmpty)
    #expect(store.skillInstallBackingOff(devFeedback, for: jarvis))
}

// MARK: Reset to bundled

@Test @MainActor func resetToBundledSendsThatSkillAloneUnguardedAndClearsTheMark() async throws {
    let (store, jarvis, host, _) = devStore(replies: [devInstalled(devFeedbackRow)], outputs: [""])
    store.setSkillDevMode(true, for: jarvis)
    jarvis.installedSkills = ["swarmhub-manager": "1.1.0", "swarmhub-feedback": "0.9.0"]
    jarvis.skillsModifiedLocally = ["swarmhub-feedback"]
    #expect(store.resetSkillToBundled(devFeedback, for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-feedback"] == "1.0.0" }
    let sent = try #require(devTurns(host).first)
    #expect(sent.contains("swarmhub_dev clear grok-jarvis swarmhub-feedback; case $? in"))
    #expect(sent.contains("swarmhub_dev reset grok-jarvis swarmhub-feedback ") && sent.contains("pressed Reset to bundled"))
    #expect(!sent.contains("swarmhub_dev check grok-jarvis swarmhub-feedback") && !sent.contains(devManagerFolder))
    #expect(sent.contains("cat > \(devFeedbackFolder)/SKILL.md <<'SWARMHUB_EOF'"))
    #expect(jarvis.skillsModifiedLocally.isEmpty && jarvis.installedSkills["swarmhub-manager"] == "1.1.0")
}

// MARK: Backoff

@Test @MainActor func aModifiedSkillNeitherBacksOffNorHoldsBackAnotherSkillsRetry() async throws {
    let (store, jarvis, host, clock) = devStore(replies: [devInstalled(devManagerRow + "," + devFeedbackRow), devInstalled(devManagerRow)],
                                                outputs: [keptFeedback, ""])
    store.setSkillDevMode(true, for: jarvis)
    // An old failure of the feedback skill, past its wait: being kept clears it instead of counting another one.
    jarvis.skillInstallFailures["swarmhub-feedback"] = SkillInstallFailure(version: "1.0.0", variant: nil, count: 3,
        lastAt: clock.date.addingTimeInterval(-3 * 86_400), reason: "Earlier refusal.")
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.skillInstallFailures["swarmhub-feedback"] == nil }
    #expect(jarvis.skillsModifiedLocally == ["swarmhub-feedback"])
    // The manager skill then fails and backs off; the kept skill stays out of the way of its retry.
    jarvis.installedSkills["swarmhub-manager"] = "1.1.0"
    store.noteSkillInstallFailure("swarmhub-manager", version: "1.2.0", variant: nil, reason: "Refused.", on: jarvis)
    #expect(store.skillBanner(for: jarvis)?.skill.name == "swarmhub-manager" && !store.installSkills(for: jarvis))
    clock.date += 15 * 60
    #expect(store.skillsToInstall(for: jarvis).map(\.name) == ["swarmhub-manager"])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && devTurns(host).count == 2 && jarvis.installedSkills["swarmhub-manager"] == "1.2.0" }
    #expect(!(devTurns(host).last ?? "").contains(devFeedbackFolder) && jarvis.skillInstallFailures.isEmpty)
}

// MARK: Dev mode off

@Test @MainActor func devModeOffStillOverwritesALocallyModifiedSkill() async throws {
    // REGRESSION: off, the commands are the plain old heredoc writes, a stale mark and a stray marker change nothing.
    let (store, jarvis, host, _) = devStore(replies: [devInstalled(devFeedbackRow)], outputs: [keptFeedback])
    jarvis.installedSkills = ["swarmhub-manager": "1.2.0", "swarmhub-feedback": "0.9.0"]
    jarvis.skillsModifiedLocally = ["swarmhub-feedback"]
    #expect(!store.isModifiedLocally(devFeedback, for: jarvis) && store.skillsToInstall(for: jarvis).map(\.name) == ["swarmhub-feedback"])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-feedback"] == "1.0.0" }
    let sent = try #require(devTurns(host).first)
    #expect(sent.contains("````sh\nmkdir -p \(devFeedbackFolder)\ncat > \(devFeedbackFolder)/SKILL.md <<'SWARMHUB_EOF'"))
    #expect(!sent.contains("swarmhub_dev") && !sent.contains("dev mode"))
    #expect(jarvis.skillInstallFailures.isEmpty)
    let plain = try #require(try store.skillInstallInstructions([devFeedback], profile: "grok-jarvis", botName: "Jarvis"))
    #expect(sent.contains(plain), "the same instructions the installer sent before dev mode existed")
}

@Test @MainActor func turningDevModeOffForgetsTheMarksAndPersistsPerBot() throws {
    let (store, jarvis, _, _) = devStore(replies: [])
    let other = Bot(name: "Other", backend: .hermes, hermesProfile: "other"); store.bots.append(other)
    store.setSkillDevMode(true, for: jarvis)
    jarvis.skillsModifiedLocally = ["swarmhub-feedback"]
    #expect(jarvis.skillDevMode && !other.skillDevMode)
    let saved = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(jarvis))
    #expect(saved.skillDevMode && saved.skillsModifiedLocally == ["swarmhub-feedback"])
    let plain = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
    #expect(!plain.contains("skillDevMode") && !plain.contains("skillsModifiedLocally"), "untouched bots encode as before")
    store.setSkillDevMode(false, for: jarvis)
    #expect(!jarvis.skillDevMode && jarvis.skillsModifiedLocally.isEmpty)
}

// MARK: The shared digest

@Test func theBundledDigestMatchesTheBoxsVector() {
    // Pinned in Tests/Updater/test_devmode.py too (devmode.files_digest / content_digest of a folder of these files).
    let files = [SkillFile(path: "SKILL.md", content: "---\nname: demo\n---\nhello\n"), SkillFile(path: "scripts/run", content: "#!/bin/sh\necho hi\n"),
                 SkillFile(path: "references/a.md", content: "\u{e4}\n")]
    #expect(SkillDevMode.contentDigest(files) == "643ff4d5ea625af5d62622e7e8779dd16e7010057e5ffcaf39496dabad96728c")
    #expect(SkillDevMode.contentDigest(files.reversed()) == SkillDevMode.contentDigest(files))
    // The heredoc adds a missing final newline, so the digest does too.
    #expect(SkillDevMode.contentDigest([SkillFile(path: "SKILL.md", content: "x")]) == SkillDevMode.contentDigest([SkillFile(path: "SKILL.md", content: "x\n")]))
}

@Test func offAndNotResetWrapsNothing() {
    let body = ["mkdir -p a", "cat > a/SKILL.md <<'SWARMHUB_EOF'\nx\nSWARMHUB_EOF"]
    #expect(SkillDevMode.wrap(body, skill: "s", profile: "p", files: [], devMode: false, reset: false) == body)
    // A reset writes into a cleared folder (so no file the bot added survives) and records the bundled digest.
    let empty = SkillDevMode.contentDigest([])
    #expect(SkillDevMode.wrap(body, skill: "s", profile: "p", files: [], devMode: true, reset: true) ==
            ["swarmhub_dev clear p s; case $? in\n0)"] + body + ["swarmhub_dev reset p s \(empty) || echo 'SWARMHUB_DEV_''FAILED:p/s' ;;\n*) echo 'SWARMHUB_DEV_''FAILED:p/s' ;;\nesac"])
    let guarded = SkillDevMode.wrap(body, skill: "s", profile: "p", files: [], devMode: true, reset: false)
    #expect(guarded.first?.hasPrefix("swarmhub_dev check p s ") == true && guarded.last?.hasSuffix("esac") == true)
}

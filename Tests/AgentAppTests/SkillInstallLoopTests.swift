import Combine
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentApp

// The 0.6.0 skill update loop: the coding skill's documentation said `kill -1`, Hermes's hardline guard refused the
// install turn's heredoc, nothing was recorded, the banner came back and every press re-sent every skill. Installs now
// skip what already matches, a turn that does not confirm a skill records a failure for that version that backs off and
// says why, and no shipped skill text trips the hardline guard. Synthetic servers only; nothing is written to a box.

private let managerSkill = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!,
    template: "---\nname: swarmhub-manager\ndescription: \"Use when. Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")
private let feedbackSkill = BundledSkill(name: "swarmhub-feedback", version: SkillVersion("1.0.0")!,
    template: "---\nname: swarmhub-feedback\ndescription: \"Report. Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.0.0\n---\n\nFile reports.\n")
private let managerFolder = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-manager"
private let feedbackFolder = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-feedback"
private let managerRow = #"{"name":"swarmhub-manager","version":"1.2.0"}"#
private let feedbackRow = #"{"name":"swarmhub-feedback","version":"1.0.0"}"#

private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

/// A manager store (Jarvis on `grok-jarvis`, both skills meant for it) whose synthetic Hermes answers chat turns with
/// `replies` in order and `/v1/skills` with `skills` (nil = 500), on a clock the test moves.
@MainActor private func loopStore(replies: [String], skills: [[String: Any]]? = nil) -> (AppStore, Bot, String, Clock) {
    let counter = LockedTrace()
    let listed = skills.map { try! JSONSerialization.data(withJSONObject: ["object": "list", "data": $0]) }
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") {
            counter.add("turn"); let reply = replies[min(counter.read().count, replies.count) - 1]
            return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])])
        }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        if path == "/v1/skills" { return listed.map { ChatParityServer.Reply(body: $0) } ?? .json(500, ["error": ["message": "Failed to enumerate skills"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k"]), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text for {{MANAGER}} ({{MANAGER_ENV}})"
    store.skillLibraryOverride = [feedbackSkill, managerSkill]
    let clock = Clock(); store.now = { clock.date }
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, host, clock)
}

private func installTurns(_ host: String) -> [String] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["instructions"] as? String ?? "" }
}

private func installed(_ rows: String) -> String {
    "Done.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[\(rows)]}\n```"
}

// MARK: Idempotent

@Test @MainActor func installSkipsSkillsWhoseVersionAlreadyMatches() async throws {
    let (store, jarvis, host, _) = loopStore(replies: [installed(feedbackRow)])
    jarvis.installedSkills = ["swarmhub-manager": "1.2.0"]
    #expect(store.skillsToInstall(for: jarvis).map(\.name) == ["swarmhub-feedback"])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.installedSkills["swarmhub-feedback"] != nil }
    let sent = try #require(installTurns(host).first)
    #expect(sent.contains("mkdir -p \(feedbackFolder)\n") && !sent.contains(managerFolder), "the current manager skill is not sent again")
    #expect(sent.contains(#"{"op":"skills_installed","bot":"grok-jarvis","skills":[{"name":"swarmhub-feedback","version":"1.0.0"}]}"#))
    // Everything matches now: no banner, and another press sends nothing.
    #expect(store.skillBanner(for: jarvis) == nil && !store.installSkills(for: jarvis))
    #expect(installTurns(host).count == 1 && jarvis.skillInstallFailures.isEmpty)
}

// MARK: Failed installs back off

@Test @MainActor func aRefusedInstallIsRecordedBacksOffAndSaysWhy() async throws {
    let refused = "The terminal refused the command: BLOCKED (hardline): kill all processes."
    let (store, jarvis, host, clock) = loopStore(replies: [refused, refused, installed(managerRow + "," + feedbackRow)])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && !jarvis.skillInstallFailures.isEmpty }
    let failure = try #require(store.skillInstallFailure(managerSkill, for: jarvis))
    #expect(failure.count == 1 && failure.version == "1.2.0" && failure.reason == "The manager did not confirm the install: “\(refused)”")
    #expect(jarvis.skillInstallFailures.keys.sorted() == ["swarmhub-feedback", "swarmhub-manager"] && jarvis.installedSkills.isEmpty)
    #expect(store.errorMessage?.hasPrefix("SwarmHub’s instructions were not installed (swarmhub-feedback for Jarvis, swarmhub-manager for Jarvis)") == true)
    // Backing off: a press sends nothing, and the banner stays to show why.
    #expect(store.skillInstallBackingOff(managerSkill, for: jarvis) && !store.installSkills(for: jarvis) && installTurns(host).count == 1)
    let banner = try #require(store.skillBanner(for: jarvis))
    let text = store.skillFailureText(try #require(store.skillInstallFailure(banner.skill, for: jarvis)), skill: banner.skill)
    #expect(text.hasPrefix("Installing swarmhub-manager v1.2.0 failed. The manager did not confirm the install: “\(refused)” Retry after "))
    // After 15 minutes one retry; failing again doubles the wait.
    clock.date += 15 * 60
    #expect(!store.skillInstallBackingOff(managerSkill, for: jarvis) && store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && store.skillInstallFailure(managerSkill, for: jarvis)?.count == 2 }
    #expect(store.skillInstallFailure(managerSkill, for: jarvis)?.retryAt == clock.date + 30 * 60)
    #expect(store.skillFailureText(try #require(store.skillInstallFailure(managerSkill, for: jarvis)), skill: managerSkill).contains("failed 2 times."))
    // A confirmed install clears it.
    clock.date += 30 * 60
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && jarvis.skillInstallFailures.isEmpty && jarvis.installedSkills.count == 2 }
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0", "swarmhub-feedback": "1.0.0"] && store.skillBanner(for: jarvis) == nil)
    #expect(installTurns(host).count == 3)
}

@Test @MainActor func aBlockMissingOneSkillFailsOnlyThatOne() async throws {
    let (store, jarvis, _, _) = loopStore(replies: [installed(feedbackRow)])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { !store.anyTurnRunning && !jarvis.skillInstallFailures.isEmpty && jarvis.installedSkills["swarmhub-feedback"] != nil }
    #expect(jarvis.skillInstallFailures.keys.sorted() == ["swarmhub-manager"])
    #expect(store.skillsToInstall(for: jarvis).isEmpty && store.skillBanner(for: jarvis)?.skill.name == "swarmhub-manager")
}

@Test @MainActor func aBoxStillOnTheOldVersionAfterAClaimCountsAsAFailure() async throws {
    let row: [String: Any] = ["name": "swarmhub-manager", "description": "Use when. Installed by SwarmHub, v1.1.0.", "category": "swarmhub"]
    let (store, jarvis, _, _) = loopStore(replies: ["ok"], skills: [row])
    jarvis.installedSkills = ["swarmhub-manager": "1.2.0"]
    await store.refreshInstalledSkills(for: jarvis)
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.1.0"])
    let failure = try #require(store.skillInstallFailure(managerSkill, for: jarvis))
    #expect(failure.count == 1 && failure.reason == "The manager reported v1.2.0 installed, but the box still has v1.1.0.")
    #expect(store.skillInstallBackingOff(managerSkill, for: jarvis))
    await store.refreshInstalledSkills(for: jarvis)
    #expect(store.skillInstallFailure(managerSkill, for: jarvis)?.count == 1, "reading the same box again is not another failure")
}

@Test @MainActor func failuresPersistAndANewBundledVersionStartsClean() throws {
    let (store, jarvis, _, clock) = loopStore(replies: ["ok"])
    store.noteSkillInstallFailure("swarmhub-manager", version: "1.2.0", variant: nil, reason: "Refused.", on: jarvis)
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(StoreFile(bots: [jarvis], groups: [])).write(to: url)
    let reloaded = try #require(try StoreFile.decode(Data(contentsOf: url)).bots.first)
    #expect(reloaded.skillInstallFailures == jarvis.skillInstallFailures && reloaded.skillInstallFailures["swarmhub-manager"]?.lastAt == clock.date)
    let fresh = Bot(name: "Fresh", backend: .hermes, hermesProfile: "fresh")
    #expect(!String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self).contains("skillInstallFailures"), "untouched bots encode as before")
    let newer = BundledSkill(name: managerSkill.name, version: SkillVersion("1.3.0")!, template: managerSkill.template)
    store.skillLibraryOverride = [feedbackSkill, newer]
    #expect(store.skillInstallFailure(newer, for: jarvis) == nil && store.skillsToInstall(for: jarvis).map(\.name) == ["swarmhub-feedback", "swarmhub-manager"])
}

@Test @MainActor func allBotsKeepsABackingOffBotListedAndSendsOnlyWhatCanGo() async throws {
    let (store, jarvis, host, clock) = loopStore(replies: ["ok"])
    let messages = BundledSkill(name: "swarmhub-messages", version: SkillVersion("1.4.6")!, template: "---\nname: swarmhub-messages\nversion: 1.4.6\n---\n\nSend.\n")
    store.skillLibraryOverride = [feedbackSkill, managerSkill, messages]
    #expect(store.missingMessagingSkills(for: jarvis).map(\.name) == ["swarmhub-feedback", "swarmhub-messages"])
    store.noteSkillInstallFailure("swarmhub-messages", version: "1.4.6", variant: nil, reason: "Refused.", on: jarvis)
    // Still missing (and still lacking for @mentions); only the part a press sends leaves it out.
    let gap = try #require(store.messagingSkillGaps(manager: jarvis).first)
    #expect(gap.skills.map(\.name) == ["swarmhub-feedback", "swarmhub-messages"] && gap.installable.map(\.name) == ["swarmhub-feedback"])
    #expect(store.missingMessagingSkills(for: jarvis).count == 2 && store.lacksMessagingSkill(jarvis))
    #expect(store.canInstallSkillsOnAllBots(manager: jarvis) && store.installSkillsOnAllBots(manager: jarvis))
    try await waitUntil { !store.anyTurnRunning && store.skillInstallFailure(feedbackSkill, for: jarvis) != nil }
    let sent = try #require(installTurns(host).first)
    #expect(sent.contains("mkdir -p \(feedbackFolder)\n") && !sent.contains("swarmhub-messages"), "the backing-off skill is not sent")
    // Both back off now: the bot stays listed as not installed, with why and when, never as "every bot has them".
    #expect(store.managersWithSkillGaps.map(\.name) == ["Jarvis"])
    #expect(store.messagingSkillGaps(manager: jarvis).first.map { $0.skills.count == 2 && $0.installable.isEmpty } == true)
    #expect(store.skillFailureText(try #require(store.skillInstallFailure(messages, for: jarvis)), skill: messages).contains("Retry after"))
    #expect(!store.canInstallSkillsOnAllBots(manager: jarvis) && !store.installSkillsOnAllBots(manager: jarvis) && installTurns(host).count == 1)
    #expect(store.messagingRetryDates(manager: jarvis) == [clock.date + 15 * 60, clock.date + 15 * 60])
    #expect(AllBotsSkillCopy.retry(store.messagingRetryDates(manager: jarvis).first)?.hasPrefix(" · install failed, retry after ") == true)
    clock.date += 15 * 60
    #expect(store.canInstallSkillsOnAllBots(manager: jarvis) && store.messagingRetryDates(manager: jarvis).isEmpty)
}

// MARK: Retry comes back on time

@Test @MainActor func aBackingOffViewSchedulesItsRedrawForTheRetryTime() {
    let (store, jarvis, _, clock) = loopStore(replies: ["ok"])
    store.noteSkillInstallFailure("swarmhub-manager", version: "1.2.0", variant: nil, reason: "Refused.", on: jarvis)
    let retryAt = clock.date + 15 * 60
    #expect(store.skillRetryDates(store.skills(for: jarvis), for: jarvis) == [retryAt] && store.skillInstallBackingOff(managerSkill, for: jarvis))
    clock.date = retryAt
    #expect(!store.skillInstallBackingOff(managerSkill, for: jarvis), "at the scheduled redraw the backoff is over and Retry is offered")
    #expect(store.skillRetryDates(store.skills(for: jarvis), for: jarvis).isEmpty)
}

private final class Renders { var times: [Date] = [] }

/// Nothing else changes when a backoff ends, so the view must redraw on its own then. Off screen, real clock: the view
/// first renders with no date; then it gets one 2 s ahead and must render again at or after it, with no other trigger.
@Test @MainActor func theRetryRefreshRedrawsAnIdleViewAtItsDate() async throws {
    let renders = Renders()
    func view(_ dates: [Date]) -> SkillRetryRefresh<Text> { SkillRetryRefresh(dates: dates) { () -> Text in renders.times.append(Date()); return Text("Retry") } }
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view([]))
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
    defer { window.close() }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return !renders.times.isEmpty }
    let due = Date().addingTimeInterval(2)
    host.rootView = view([due])
    try await waitUntil { host.layoutSubtreeIfNeeded(); return renders.times.contains { $0 >= due } }
}

// MARK: Hermes hardline guard

/// Hermes's hardline rules a line of documentation can trip, ported from Hermes 0.22.0 `tools/approval_detection.py`
/// (plus 0.20.5's unanchored `kill … -1`). A match refuses the whole terminal command whatever the approval mode, so an
/// install whose heredoc carries one never lands. Hermes splits commands on `;`, `&`, `|` and treats a backtick as a
/// command start, so those count as starts here too. `sim/test_skill_guard_phrases.py` checks the same on Linux.
private let start = #"(?:^|[\n`;&|]|\$\()\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+(?:\w+=\S*\s+)*)?(?:(?:exec|nohup|setsid|time)\s+)*\s*"#
private let rm = start + #"rm\s+(-\S*\s+)*"#
private func rmPath(_ alt: String) -> String { #"(?:["'](?:"# + alt + #")["']|(?:"# + alt + #")(?:\s|$|[)`;|&]))"# }
private let systemDirs = #"/home|/home/\*|/root|/root/\*|/etc|/etc/\*|/usr|/usr/\*|/var|/var/\*|/bin|/bin/\*|/sbin|/sbin/\*|/boot|/boot/\*|/lib|/lib/\*"#
private let hardline: [NSRegularExpression] = [
    rm + rmPath(#"/(?:(?:\.\.?)?/)*(?:\.\.?)?\**|/ \*"#), rm + rmPath(systemDirs), rm + rmPath(#"(?:~|\$\{?HOME\}?)(?:/?|/\*)?"#),
    start + #"mkfs(\.[a-z0-9]+)?\b"#, start + #"dd\b[^\n]*\bof=/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*"#,
    #">\s*/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*\b"#, #":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#,
    #"\bkill\s+(-\S+\s+)*-1\b"#, start + #"(shutdown|reboot|halt|poweroff)\b"#, start + #"init\s+[06]\b"#,
    start + #"systemctl\s+(poweroff|reboot|halt|kexec)\b"#, start + #"telinit\s+[06]\b"#,
].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .anchorsMatchLines]) }

private func hardlineMatch(_ text: String) -> String? {
    for rule in hardline {
        if let found = rule.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(found.range, in: text) { return String(text[range]) }
    }
    return nil
}

@Test func theGuardPortCatchesThe060Sentence() {
    #expect(hardlineMatch("reach only the verifier's own process tree and groups (`verify_signals.py`; `kill -1`, the") == "kill -1")
    #expect(hardlineMatch("echo done\nreboot now") != nil && hardlineMatch("a broadcast signal to PID -1, the launcher") == nil)
}

@Test @MainActor func noShippedSkillTextTripsHermesHardlineGuard() throws {
    let (store, _, _, _) = loopStore(replies: ["ok"])
    store.skillLibraryOverride = nil; store.managerTemplateOverride = nil
    #expect(store.skillLibrary.map(\.name) == ["swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages"])
    // Skill dev mode's guarded commands and Reset to bundled's too.
    let names = Set(store.skillLibrary.map(\.name))
    for order in CodingOrder.allCases {
        for (devMode, reset) in [(false, Set<String>()), (true, Set<String>()), (true, names)] {
            let install = try #require(try store.skillInstallCommands(store.skillLibrary, profile: "grok-jarvis", codingOrder: order,
                                                                       devMode: devMode, reset: reset))
            for command in install.commands {
                #expect(hardlineMatch(command) == nil, "Hermes would refuse: \(hardlineMatch(command) ?? "") in \(command.prefix(120))")
            }
        }
    }
}

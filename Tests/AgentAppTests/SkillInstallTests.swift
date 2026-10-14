import Foundation
import Testing
@testable import AgentApp

// P27 store level: Install sends the manager one turn with the library's content in heredocs, the skills_installed block
// records versions, the banner and editor states follow, installed-current turns carry only a pointer, and /v1/skills
// confirms the record when it works. Synthetic servers only; nothing is written to a box.

private let marker = "P27-MANAGER-TEXT-MARKER"
private let skill = BundledSkill(name: "swarmhub-manager", version: SkillVersion("1.2.0")!,
                                 template: "---\nname: swarmhub-manager\ndescription: \"Use when. Installed by SwarmHub, v{{VERSION}}.\"\nversion: 1.2.0\n---\n\n{{MANAGER_TEXT}}\n")

/// A manager store (Jarvis on `grok-jarvis`) whose synthetic Hermes answers chat turns with `replies` in order and
/// `/v1/skills` with `skills` (nil = 500 like stock 0.22.0).
@MainActor private func skillStore(replies: [String] = ["ok"], skills: [[String: Any]]? = nil) -> (AppStore, Bot, String) {
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
    store.managerTemplateOverride = "\(marker) you are {{MANAGER}} ({{MANAGER_ENV}})"
    store.skillLibraryOverride = [skill]
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    store.bots = [jarvis]; store.selectedBot = jarvis
    return (store, jarvis, host)
}

private func sentInstructions(_ host: String) -> [String] {
    ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.map { $0.body?["instructions"] as? String ?? "" }
}

private func installedBlock(_ bot: String, _ version: String) -> String {
    "Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"\(bot)\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"\(version)\",\"content\":\"IGNORED\"}]}\n```"
}

// MARK: Install

@Test @MainActor func installTurnCarriesTheLibraryContentForANamedProfile() async throws {
    let (store, jarvis, host) = skillStore(replies: [installedBlock("grok-jarvis", "1.2.0")])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { store.isIdle && jarvis.installedSkills["swarmhub-manager"] != nil }
    let sent = try #require(sentInstructions(host).first)
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "grok-jarvis", managerTemplate: store.managerTemplateOverride))
    let folder = "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-manager"
    #expect(sent.hasPrefix("You are Jarvis.\n\n") && sent.contains("That press is his yes"))
    #expect(sent.contains("mkdir -p \(folder)\ncat > \(folder)/SKILL.md <<'SWARMHUB_EOF'\n\(rendered)SWARMHUB_EOF\n"))
    #expect(sent.contains(#"{"op":"skills_installed","bot":"grok-jarvis","skills":[{"name":"swarmhub-manager","version":"1.2.0"}]}"#))
    #expect(jarvis.messages.first { $0.role == .user }?.content == "Install SwarmHub’s instructions for Jarvis.")
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"])
}

@Test @MainActor func installForTheDefaultProfileWritesUnderHermesSkills() async throws {
    let (store, jarvis, host) = skillStore()
    jarvis.hermesProfile = "default"
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { store.isIdle }
    let sent = try #require(sentInstructions(host).first)
    #expect(sent.contains("mkdir -p ~/.hermes/skills/swarmhub/swarmhub-manager\ncat > ~/.hermes/skills/swarmhub/swarmhub-manager/SKILL.md <<'SWARMHUB_EOF'"))
    #expect(!sent.contains("profiles/default"))
}

@Test @MainActor func recordingTakesOnlyLibrarySkillsAndNeverTheReplysContent() async throws {
    let other = "```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"evil-skill\",\"version\":\"9.0.0\"},{\"name\":\"swarmhub-manager\",\"version\":\"7.0.0\"}]}\n```"
    let (store, jarvis, _) = skillStore(replies: [other])
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { store.isIdle && !jarvis.installedSkills.isEmpty }
    // Unknown names are dropped; a version newer than this build ships is recorded as the bundled one.
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"])
}

@Test @MainActor func anotherConnectionsBotIsUntouched() async throws {
    let (store, jarvis, _) = skillStore(replies: [installedBlock("grok-jarvis", "1.2.0")])
    // The same profile name behind another connection, with its own manager role there.
    let remote = Bot(name: "Jarvis elsewhere", backend: .hermes, hermesProfile: "grok-jarvis"); remote.hermesBaseURL = "https://other.example.com/v1"
    remote.canManageBots = true
    store.bots.insert(remote, at: 0)
    #expect(store.isManager(remote) && store.manager(for: jarvis)?.id == jarvis.id)
    #expect(store.installSkills(for: jarvis))
    try await waitUntil { store.isIdle && !jarvis.installedSkills.isEmpty }
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.2.0"] && remote.installedSkills.isEmpty)
}

@Test @MainActor func noManagerMeansNoInstall() {
    let (store, jarvis, _) = skillStore()
    let elsewhere = Bot(name: "Far", backend: .hermes, hermesProfile: "far"); elsewhere.hermesBaseURL = "https://other.example.com/v1"
    store.bots.append(elsewhere)
    #expect(store.manager(for: elsewhere) == nil && !store.installSkills(for: elsewhere))
    jarvis.canManageBots = false
    #expect(!store.installSkills(for: jarvis) && store.skills(for: jarvis).isEmpty)
}

// MARK: Notify

@Test @MainActor func bannerFollowsMissingOutdatedCurrentAndNotNowPerVersion() throws {
    let url = temporaryStore()
    let (store, jarvis, _) = skillStore()
    #expect(store.skillBanner(for: jarvis)?.state == .missing)
    #expect(AppStore.skillBannerText(bot: "Jarvis", state: .missing) == "SwarmHub’s instructions for Jarvis need installing")
    jarvis.installedSkills = ["swarmhub-manager": "1.1.0"]
    #expect(store.skillBanner(for: jarvis)?.state == .outdated(installed: "1.1.0"))
    #expect(AppStore.skillBannerText(bot: "Jarvis", state: .outdated(installed: "1.1.0")) == "SwarmHub’s instructions for Jarvis need updating")
    store.snoozeSkillBanner(for: jarvis)
    #expect(store.skillBanner(for: jarvis) == nil && jarvis.skillBannerSnoozed == "1.2.0")
    // Not now persists with the bot…
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(StoreFile(bots: [jarvis], groups: [])).write(to: url)
    let reloaded = try #require(try StoreFile.decode(Data(contentsOf: url)).bots.first)
    #expect(reloaded.skillBannerSnoozed == "1.2.0" && reloaded.installedSkills == ["swarmhub-manager": "1.1.0"])
    // …until the next bundled version.
    store.skillLibraryOverride = [BundledSkill(name: skill.name, version: SkillVersion("1.3.0")!, template: skill.template)]
    #expect(store.skillBanner(for: jarvis)?.state == .outdated(installed: "1.1.0"))
    jarvis.installedSkills = ["swarmhub-manager": "1.3.0"]
    #expect(store.skillBanner(for: jarvis) == nil)
    // Only the manager gets a banner.
    let plain = Bot(name: "Plain", backend: .hermes, hermesProfile: "plain"); store.bots.append(plain)
    #expect(store.skillBanner(for: plain) == nil && store.skills(for: plain).isEmpty)
}

@Test func editorRowsSayStateInPlainWords() {
    let bundled = SkillVersion("1.2.0")!
    #expect(SwarmHubSkillsSection.stateText(.missing, bundled: bundled) == "Not installed · v1.2.0 available")
    #expect(SwarmHubSkillsSection.stateText(.outdated(installed: "1.1.0"), bundled: bundled) == "v1.1.0 installed · v1.2.0 available")
    #expect(SwarmHubSkillsSection.stateText(.current, bundled: bundled) == "v1.2.0 installed")
}

// MARK: Tokens

@Test @MainActor func installedCurrentSendsThePointerOtherwiseTheFullText() async throws {
    let (store, jarvis, host) = skillStore()
    func turn(_ text: String) async throws { #expect(store.send(text: text)); try await waitUntil { store.isIdle } }
    try await turn("list bots")                                   // missing → full text
    jarvis.installedSkills = ["swarmhub-manager": "1.1.0"]; store.managementExchanges = [:]
    try await turn("list bots")                                   // outdated → full text
    jarvis.installedSkills = ["swarmhub-manager": "1.2.0"]; store.managementExchanges = [:]
    try await turn("switch all agents to 6.1 sol")                // current → pointer only
    store.managementExchanges = [:]
    try await turn("good morning")                                // ordinary → nothing
    let sent = sentInstructions(host)
    #expect(sent.map { $0.contains(marker) } == [true, true, false, false])
    #expect(sent[2] == "You are Jarvis.\n\n" + AppStore.skillPointer)
    #expect(sent[3] == "You are Jarvis.")
}

// MARK: /v1/skills

@Test @MainActor func skillsListUpdatesTheRecordAndA500LeavesIt() async throws {
    let row: [String: Any] = ["name": "swarmhub-manager", "description": "Use when. Installed by SwarmHub, v1.1.0.", "category": "swarmhub"]
    let decoy: [String: Any] = ["name": "swarmhub-manager-x", "description": "Installed by SwarmHub, v9.9.9.", "category": "other"]
    let (store, jarvis, _) = skillStore(skills: [row, decoy])
    await store.refreshInstalledSkills(for: jarvis)
    #expect(jarvis.installedSkills == ["swarmhub-manager": "1.1.0"])
    let (empty, emptyJarvis, _) = skillStore(skills: [decoy])
    emptyJarvis.installedSkills = ["swarmhub-manager": "1.2.0"]
    await empty.refreshInstalledSkills(for: emptyJarvis)
    #expect(emptyJarvis.installedSkills.isEmpty, "a working list without it means it is gone")
    let (broken, brokenJarvis, _) = skillStore(skills: nil)
    brokenJarvis.installedSkills = ["swarmhub-manager": "1.2.0"]
    await broken.refreshInstalledSkills(for: brokenJarvis)
    #expect(brokenJarvis.installedSkills == ["swarmhub-manager": "1.2.0"])
}

import Foundation
import Testing
@testable import AgentApp

// P31 B: the bundled swarmhub-coding skill (rendered per bot with its coding order), the order's settings resolution,
// the outdated rule with variants, and the code-job shell test run under /bin/sh and /bin/dash. Synthetic only.

private func codingSkill() throws -> BundledSkill { try #require(SkillLibrary.bundled().first { $0.name == "swarmhub-coding" }) }

/// Jarvis (manager, `grok-jarvis`) and Coder (`coder`) on one synthetic Hermes connection that answers chat turns
/// with `reply`.
@MainActor private func codingStore(reply: String = "ok") -> (AppStore, Bot, Bot, String) {
    let (host, hermes) = ChatParityServer.serve(features: ["session_chat_streaming": true]) { request, _ in
        let path = request.url!.path
        if path.hasSuffix("/chat/stream") { return .sse([("assistant.delta", ["delta": reply]), ("run.completed", [:])]) }
        if path == "/api/sessions" { return .json(200, ["session": ["id": "s-manager"]]) }
        return .json(404, ["error": "no route"])
    }
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in hermes }, keyStore: InMemoryKeyStore(["hermes.grok-jarvis": "k"]), defaults: isolatedDefaults())
    store.managerTemplateOverride = "manager text for {{MANAGER}} ({{MANAGER_ENV}})"
    let jarvis = Bot(name: "Jarvis", persona: "You are Jarvis.", backend: .hermes, hermesProfile: "grok-jarvis")
    jarvis.canManageBots = true
    let coder = Bot(name: "Coder", backend: .hermes, hermesProfile: "coder")
    store.bots = [jarvis, coder]; store.selectedBot = coder
    return (store, jarvis, coder, host)
}

// MARK: Rendering

@Test func codingSkillShipsWithItsScript() throws {
    let skill = try codingSkill()
    #expect(skill.version == SkillVersion("1.0.0")!)
    let fields = SkillLibrary.frontmatter(skill.template)
    #expect(fields["author"] == "SwarmHub" && skill.template.contains("metadata:\n  swarmhub:\n    source: swarmhub"))
    let description = try #require(fields["description"])
    #expect(description.hasPrefix("Use for any coding task") && description.contains("supersedes the claude-code, codex and opencode skills")
            && description.hasSuffix("Installed by SwarmHub, v{{VERSION}}."))
    let script = try #require(skill.files.first { $0.path == "scripts/code-job" })
    #expect(skill.files.map(\.path) == ["scripts/code-job"] && script.isExecutable && script.content.hasPrefix("#!/bin/sh\n"))
    // POSIX only: none of the tools the brief rules out, no bash-only syntax.
    #expect(script.content.range(of: #"(?m)(^|[;&|(]|then|do)\s*(timeout|flock|setsid|local)\s"#, options: .regularExpression) == nil)
    for banned in ["[[ ", "function ", "<(", "$'", "pipefail", "#!/bin/bash", "declare ", "source "] {
        #expect(!script.content.contains(banned), "\(banned)")
    }
    #expect(!script.content.contains("SWARMHUB_EOF") && !skill.template.contains("SWARMHUB_EOF"))
}

@Test(arguments: CodingOrder.allCases) func renderedCodingSkillCarriesThisBotsOrder(_ order: CodingOrder) throws {
    let skill = try codingSkill()
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "coder", managerTemplate: nil, codingOrder: order))
    #expect(!rendered.contains("{{"))
    #expect(rendered.contains("~/.hermes/profiles/coder/skills/swarmhub/swarmhub-coding/scripts/code-job --bot coder --order \(order.argument) --dir"))
    #expect(SkillLibrary.advertisedVersion(in: SkillLibrary.frontmatter(rendered)["description"] ?? "") == "1.0.0")
    #expect(rendered.contains("CODE_JOB_USE_DELEGATE") && rendered.contains("delegate_task") && rendered.contains("claude.token"))
    #expect(SkillLibrary.variant(of: skill, codingOrder: order) == order.argument)
    let defaultBot = try #require(SkillLibrary.render(skill, forProfile: "default", managerTemplate: nil, codingOrder: order))
    #expect(defaultBot.contains("~/.hermes/skills/swarmhub/swarmhub-coding/scripts/code-job --bot default "))
}

@Test func onlyTheCodingSkillHasAVariant() throws {
    let manager = try #require(SkillLibrary.bundled().first { $0.name == SkillLibrary.managerSkill })
    #expect(SkillLibrary.variant(of: manager, codingOrder: .codexOnly) == nil)
    #expect(CodingOrder.allCases.map(\.argument) == ["claude,codex,hermes", "codex,claude,hermes", "claude", "codex", "hermes"])
    #expect(CodingOrder.allCases.map(\.title) == ["Claude Code → Codex → Hermes sub-agent", "Codex → Claude Code → Hermes sub-agent",
                                                   "Claude Code only", "Codex only", "Hermes sub-agent only"])
}

@Test @MainActor func installTurnCarriesTheScriptAndTheVariant() throws {
    let (store, _, coder, _) = codingStore()
    coder.modelSettings = BotModelSettings(codingAgent: .codexClaudeHermes)
    let skills = store.skills(for: coder)
    #expect(skills.map(\.name) == ["swarmhub-coding"], "every Hermes bot gets it; the manager skill only the manager")
    let text = try #require(try store.skillInstallInstructions(skills, profile: "coder", botName: "Coder", codingOrder: store.codingOrder(for: coder)))
    let folder = "~/.hermes/profiles/coder/skills/swarmhub/swarmhub-coding"
    let script = try #require(try codingSkill().files.first)
    #expect(text.contains("mkdir -p \(folder) \(folder)/scripts\n"))
    #expect(text.contains("cat > \(folder)/scripts/code-job <<'SWARMHUB_EOF'\n\(script.content)SWARMHUB_EOF\nchmod 755 \(folder)/scripts/code-job\n"))
    #expect(text.contains("--order codex,claude,hermes"))
    #expect(text.contains(#"{"name":"swarmhub-coding","version":"1.0.0","variant":"codex,claude,hermes"}"#))
}

// MARK: Settings resolution

@Test func botOrderBeatsTheSwarmHubDefault() {
    #expect(CodingOrder.resolve(bot: nil, appDefault: nil) == (.claudeCodexHermes, .appDefault))
    #expect(CodingOrder.resolve(bot: nil, appDefault: .codexOnly) == (.codexOnly, .appDefault))
    #expect(CodingOrder.resolve(bot: .hermesOnly, appDefault: .codexOnly) == (.hermesOnly, .bot))
}

@Test @MainActor func storeResolvesEachBotsOrder() {
    let (store, jarvis, coder, _) = codingStore()
    #expect(store.codingOrder(for: coder) == .standard)
    store.modelDefaults.codingAgent = .codexClaudeHermes
    #expect(store.codingOrder(for: coder) == .codexClaudeHermes && store.codingOrder(for: jarvis) == .codexClaudeHermes)
    coder.modelSettings = BotModelSettings(codingAgent: .claudeOnly)
    #expect(store.codingOrder(for: coder) == .claudeOnly && store.codingOrder(for: jarvis) == .codexClaudeHermes)
}

@Test func codingOrderPersistsAndOldStoresStillLoad() throws {
    let settings = BotModelSettings(codingAgent: .codexOnly)
    #expect(try JSONDecoder().decode(BotModelSettings.self, from: JSONEncoder().encode(settings)) == settings)
    #expect(!settings.isEmpty && BotModelSettings().isEmpty)
    let old = try JSONDecoder().decode(BotModelSettings.self, from: Data(#"{"conversation":{"kind":"box"}}"#.utf8))
    #expect(old.codingAgent == nil && old.conversation == .box)
    let later = try JSONDecoder().decode(ModelDefaults.self, from: Data(#"{"codingAgent":"gemini,claude"}"#.utf8))
    #expect(later.codingAgent == nil && later.isEmpty, "an order this build does not know reads as unset")
    let defaults = ModelDefaults(codingAgent: .hermesOnly)
    let decoded = try JSONDecoder().decode(ModelDefaults.self, from: JSONEncoder().encode(defaults))
    #expect(!defaults.isEmpty && decoded == defaults)
}

@Test @MainActor func editorSavesTheOrderForHermesBotsOnly() {
    let (store, _, coder, _) = codingStore()
    var fields = BotEditorFields(bot: coder)
    #expect(fields.codingAgent == nil)
    fields.codingAgent = .codexOnly
    fields.apply(to: coder, store: store, avatarTouched: false)
    #expect(coder.modelSettings?.codingAgent == .codexOnly && BotEditorFields(bot: coder).codingAgent == .codexOnly)
    fields.codingAgent = nil
    fields.apply(to: coder, store: store, avatarTouched: false)
    #expect(coder.modelSettings == nil, "back to the default leaves the bot untouched")
    fields.codingAgent = .codexOnly; fields.backend = .mock
    fields.apply(to: coder, store: store, avatarTouched: false)
    #expect(coder.modelSettings?.codingAgent == nil)
}

// MARK: Outdated with variants

@Test func variantRule() {
    let bundled = SkillVersion("1.0.0")!
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: bundled, installedVariant: "claude,codex,hermes", wantedVariant: "claude,codex,hermes") == .current)
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: bundled, installedVariant: "claude,codex,hermes", wantedVariant: "codex") == .changed(installed: "1.0.0"))
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: bundled, installedVariant: nil, wantedVariant: "codex") == .changed(installed: "1.0.0"))
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: bundled, installedVariant: "stale", wantedVariant: nil) == .current, "no wanted variant, nothing to compare")
    #expect(SkillLibrary.state(installed: "0.9.0", bundled: bundled, installedVariant: "codex", wantedVariant: "codex") == .outdated(installed: "0.9.0"))
    #expect(SkillLibrary.state(installed: nil, bundled: bundled, wantedVariant: "codex") == .missing)
    #expect(SwarmHubSkillsSection.stateText(.changed(installed: "1.0.0"), bundled: bundled) == "v1.0.0 installed · coding agent changed, needs updating")
}

@Test @MainActor func changingTheOrderRaisesTheUpdateBannerAndNotNowCoversThatOrderOnly() throws {
    let (store, jarvis, coder, _) = codingStore()
    let skill = try codingSkill()
    // A bot without the skill: offered in its editor, no banner; its manager's banner offers what the manager lacks.
    #expect(store.skillBanner(for: coder) == nil && store.skillState(skill, for: coder) == .missing)
    #expect(store.skillBanner(for: jarvis)?.skill.name == SkillLibrary.managerSkill)
    jarvis.installedSkills = [SkillLibrary.managerSkill: "1.0.2"]
    #expect(store.skillBanner(for: jarvis)?.skill.name == "swarmhub-coding" && store.skillBanner(for: jarvis)?.state == .missing)
    coder.installedSkills = [skill.name: "1.0.0"]; coder.installedSkillVariants = [skill.name: "claude,codex,hermes"]
    #expect(store.skillState(skill, for: coder) == .current && store.skillBanner(for: coder) == nil)
    store.modelDefaults.codingAgent = .codexOnly
    #expect(store.skillBanner(for: coder)?.state == .changed(installed: "1.0.0"))
    #expect(AppStore.skillBannerText(bot: "Coder", state: .changed(installed: "1.0.0")) == "SwarmHub’s instructions for Coder need updating")
    store.snoozeSkillBanner(for: coder)
    #expect(store.skillBanner(for: coder) == nil && coder.skillBannerSnoozed == "swarmhub-coding 1.0.0 codex")
    coder.modelSettings = BotModelSettings(codingAgent: .claudeOnly)
    #expect(store.skillBanner(for: coder)?.state == .changed(installed: "1.0.0"), "another order shows it again")
    coder.modelSettings = BotModelSettings(codingAgent: .claudeCodexHermes)
    #expect(store.skillBanner(for: coder) == nil, "back to what is installed")
    // No manager on the connection: no banner, the editor says it needs one (today's behaviour).
    jarvis.canManageBots = false
    coder.modelSettings = BotModelSettings(codingAgent: .codexOnly); coder.skillBannerSnoozed = nil
    #expect(store.skillBanner(for: coder) == nil && store.manager(for: coder) == nil && !store.installSkills(for: coder))
}

@Test @MainActor func installRecordsTheVariantFromTheBlock() async throws {
    let reply = "Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"coder\",\"skills\":[{\"name\":\"swarmhub-coding\",\"version\":\"1.0.0\",\"variant\":\"codex\"}]}\n```"
    let (store, jarvis, coder, host) = codingStore(reply: reply)
    coder.modelSettings = BotModelSettings(codingAgent: .codexOnly)
    #expect(store.installSkills(for: coder))
    try await waitUntil { store.isIdle && coder.installedSkills["swarmhub-coding"] != nil }
    let sent = ChatParityServer.requests(host).filter { $0.path.hasSuffix("/chat/stream") }.compactMap { $0.body?["instructions"] as? String }
    #expect(sent.count == 1 && sent[0].contains("--order codex --dir") && sent[0].contains("for Coder (profile `coder`)"))
    #expect(jarvis.messages.first { $0.role == .user }?.content == "Install SwarmHub’s instructions for Coder.")
    #expect(coder.installedSkills == ["swarmhub-coding": "1.0.0"] && coder.installedSkillVariants == ["swarmhub-coding": "codex"])
    #expect(store.skillState(try codingSkill(), for: coder) == .current)
    // The variant survives a save and reload with the bot; a bot without one encodes as before.
    let url = temporaryStore()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(StoreFile(bots: [coder, jarvis], groups: [])).write(to: url)
    let reloaded = try StoreFile.decode(Data(contentsOf: url)).bots
    #expect(reloaded.first?.installedSkillVariants == ["swarmhub-coding": "codex"] && reloaded.last?.installedSkillVariants.isEmpty == true)
    #expect(!String(decoding: try JSONEncoder().encode(jarvis), as: UTF8.self).contains("installedSkillVariants"))
}

@Test func blockVariantIsOptionalAndChecked() {
    func parse(_ row: String) -> [SwarmhubOp]? { SwarmhubBlock.ops(in: "```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"coder\",\"skills\":[\(row)]}\n```") }
    #expect(parse(#"{"name":"swarmhub-coding","version":"1.0.0","variant":"claude,codex,hermes"}"#)
            == [.skillsInstalled(bot: "coder", skills: [.init(name: "swarmhub-coding", version: "1.0.0", variant: "claude,codex,hermes")])])
    #expect(parse(#"{"name":"swarmhub-manager","version":"1.0.1"}"#) == [.skillsInstalled(bot: "coder", skills: [.init(name: "swarmhub-manager", version: "1.0.1")])])
    #expect(parse(#"{"name":"swarmhub-coding","version":"1.0.0","variant":"$(rm -rf ~)"}"#)
            == [.skillsInstalled(bot: "coder", skills: [.init(name: "swarmhub-coding", version: "1.0.0", variant: nil)])])
}

// MARK: code-job

private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

/// `Tests/Scripts/code-job-test.sh` under each shell present: stub CLIs, a temp HOME, every case must pass.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func codeJobShellTestPasses(_ shell: String) throws {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = [repoRoot.appending(path: "Tests/Scripts/code-job-test.sh").path, repoRoot.appending(path: "Resources/Skills/swarmhub-coding/scripts/code-job").path]
    // Only what the test needs: no inherited agent keys or the developer's PATH (no real claude/codex).
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "CODE_JOB_SH": shell]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(shell):\n\(output)")
    #expect(output.contains("code-job tests under \(shell): 12 passed, 0 failed"), "\(output)")
    #expect(!output.contains("FAIL"), "\(output)")
}

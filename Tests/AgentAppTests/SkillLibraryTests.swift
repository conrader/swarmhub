import Foundation
import Testing
@testable import AgentApp

// P27 pure parts: the model intent, the model recipe in the manager text, and the bundled skill library (synthetic only).

// MARK: Intent

@Test(arguments: [
    "can you switch all agents to 6.1 sol ?", "switch every bot to gpt-5.5", "change the model of all bots to claude opus",
    "set the model of the research agent to sonnet", "upgrade all assistants to 6.2", "move every agent to terra",
    "use opus for all bots", "przełącz wszystkie boty na 6.1 sol", "zmień model wszystkich agentów na gpt-5.5",
    "ustaw modele wszystkich botów na claude", "zmien wszystkie boty na sol"
])
func modelRequestsAreManagementIntent(_ text: String) { #expect(ManagementIntent.matches(text), "\(text)") }

@Test(arguments: [
    "Switch the lights off", "change of plans for tonight", "set an alarm for 6.30", "use all the flour",
    "can you change every resolution in this doc", "switch all tabs to dark mode", "move every meeting to friday",
    "Zmień godzinę spotkania na 10.30", "ustaw przypomnienie na jutro", "what model are you?", "I love the terrace"
])
func ordinaryChatIsNoModelIntent(_ text: String) { #expect(!ManagementIntent.matches(text), "\(text)") }

@Test func changeModelMenuItemFillsAPlainRequest() {
    #expect(ManageBotsAction.allCases.contains(.changeModel) && ManageBotsAction.changeModel.title == "Change model…")
    #expect(ManageBotsAction.changeModel.request() == "Change the model of <bots> to ")
    #expect(ManageBotsAction.changeModel.request(bot: "grok-rapper") == "Change the model of grok-rapper to ")
}

// MARK: Template

/// P30: the model recipe (skill 1.0.1), byte for byte: two bots at a time, values a bot already has skipped, Hermes'
/// stderr kept out of the log, started with the terminal tool's background option (it refuses nohup). P31 D+E (skill
/// 1.2.0): the skip check compares the current value with quotes stripped, so '', "" and a missing key are empty.
private let modelRecipe = ##"""
Change the model (one bot, some, or all): ask first, naming model, provider and bots. Start it as a background process of your terminal tool (its background option, not nohup/setsid, which it refuses):
```
export MODEL=<model> PROV=<provider, e.g. openai-codex> KM=model.default KP=model.provider
cd ~/.hermes && : > swarmhub-model.err && printf '%s\n' <names> | xargs -P 2 -n 1 sh -c 'N=$1; F=profiles/$N/config.yaml; [ "$N" = default ] && F=config.yaml; r=ok; for KV in "$KM=$MODEL" "$KP=$PROV"; do K=${KV%%=*}; V=${KV#*=}; C=$(sed -n "/^${K%%.*}:/,/^[^ ]/s/^  *${K#*.}: *//p" "$F" | head -n 1 | tr -d "\"\047 "); [ "$C" = "$V" ] || hermes -p "$N" config set "$K" "$V" >/dev/null 2>>swarmhub-model.err || r=FAILED; done; echo "$N $r"' sh > swarmhub-model.log; echo DONE >> swarmhub-model.log
```
`<names>` for all bots: `default $(ls ~/.hermes/profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')`. The sub-agent/coding model only when asked: the same with `KM=delegation.model KP=delegation.provider`; empty MODEL and PROV clear it (sub-agents then use each bot's model). A value a bot already has is skipped; each change takes ~4 s, two bots at a time. Wait for the process, then `cat ~/.hermes/swarmhub-model.log` (ends with DONE) and report ok/FAILED per bot; for FAILED show the last lines of `~/.hermes/swarmhub-model.err`. Say that SwarmHub chats with their own chosen model keep it (changed in that chat's model menu).
"""##

@Test func managerTextCarriesTheModelRecipeWithinItsBudget() throws {
    let template = try #require(BotManagerText.template())
    // P30: the exact recipe block took the text past 4 KiB; P35's list, connect and restore recipes to 6.4 KiB; P31 C's
    // accounts recipes to 10 KiB, then split out into recipes/box.md and recipes/accounts.md, read on demand.
    #expect(template.utf8.count <= 4_600, "manager-hermes.md is \(template.utf8.count) bytes")
    #expect(template.contains(modelRecipe))
    #expect(template.contains(#"hermes -p "$N" config set "$K" "$V""#) && template.contains("KM=model.default KP=model.provider"))
    #expect(template.contains("xargs -P 2 -n 1") && template.contains("2>>swarmhub-model.err") && template.contains("echo DONE >> swarmhub-model.log"))
    #expect(!template.contains("nohup sh -c") && !template.contains("10 s per bot"))
    #expect(template.contains("default $(ls ~/.hermes/profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')"))
    #expect(template.contains("KM=delegation.model KP=delegation.provider") && template.contains("ask first"))
    for profile in ["default", "grok-jarvis"] {
        let filled = BotManagerText.filled(template, managerProfile: profile)
        #expect(!filled.contains("{{"), "\(profile)")
    }
    // No command that reads a secret out: the only .env read feeds the HMAC directly; nothing cats/echoes keys or config.
    let commands = ([template] + BotManagerText.Recipe.allCases.compactMap(BotManagerText.recipe)).joined().lowercased()
    for forbidden in ["cat ~/.hermes/.env", "cat \"$p/.env\"", "echo $mk", "echo $k", "printenv", "env |", "cat ~/.hermes/config.yaml", "security "] {
        #expect(!commands.contains(forbidden), "\(forbidden)")
    }
}

// MARK: Library

@Test func libraryListsTheBundledManagerSkill() throws {
    let skills = SkillLibrary.bundled()
    #expect(skills.map(\.name) == ["swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages"], "P31: swarmhub-coding joins it; P34: swarmhub-messages; P36: swarmhub-feedback")
    let skill = try #require(skills.first { $0.name == SkillLibrary.managerSkill })
    #expect(skill.files.map(\.path) == ["references/accounts.md", "references/box.md", "references/capacity.md", "references/models.md"], "P31 C, D+E: the recipe files as references")
    #expect(skill.files.map(\.content) == [BotManagerText.recipe(.accounts), BotManagerText.recipe(.box), BotManagerText.recipe(.capacity), BotManagerText.recipe(.models)], "shipped from Resources/BotManager/recipes")
    #expect(SkillLibrary.bundled(managerReferences: nil).map(\.name) == ["swarmhub-coding", "swarmhub-feedback", "swarmhub-messages"], "no recipes, no manager skill")
    #expect(skill.version == SkillVersion("1.3.0")!, "P31 D+E: + the models and capacity references; P56: + Heartbeat")
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: skill.version) == .outdated(installed: "1.0.0"), "bots on 1.0.0 get the Update banner")
    let fields = SkillLibrary.frontmatter(skill.template)
    #expect(fields["name"] == "swarmhub-manager" && fields["version"] == skill.version.description)
    #expect(skill.template.contains("metadata:\n  swarmhub:\n    source: swarmhub"))
}

@Test func renderedSkillIsTheManagerTextForThatProfile() throws {
    let skill = try #require(SkillLibrary.bundled().first { $0.name == SkillLibrary.managerSkill })
    let template = try #require(BotManagerText.template())
    for profile in ["default", "grok-jarvis"] {
        let rendered = try #require(SkillLibrary.render(skill, forProfile: profile, managerTemplate: template))
        #expect(!rendered.contains("{{"), "\(profile)")
        let fields = SkillLibrary.frontmatter(rendered)
        #expect(fields["name"] == "swarmhub-manager" && SkillVersion(fields["version"] ?? "") == skill.version)
        let description = try #require(fields["description"])
        #expect(description.hasPrefix("Use when") && description.contains("models") && SkillLibrary.advertisedVersion(in: description) == skill.version.description)
        // The body is the core manager text rendered for this profile (one source of truth), then when to read each recipe.
        let manager = BotManagerText.filled(template, managerProfile: profile).trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = SkillLibrary.installPath(SkillLibrary.managerSkill, profile: profile)
        #expect(rendered.contains(manager + "\n\nWhen asked to list every bot, connect bots made before SwarmHub"))
        #expect(rendered.contains("first read `\(folder)/references/capacity.md` (`cat` it).\n\n## Heartbeat\n") && rendered.contains("first read `\(folder)/references/box.md`"))
        #expect(rendered.hasSuffix("SwarmHub reads it back and asks Konrad whether to keep the box's schedule or put its own back.\n"), "P56: the Heartbeat section ends it")
        #expect(rendered.contains("first read `\(folder)/references/accounts.md`") && rendered.contains("first read `\(folder)/references/models.md`"))
        #expect(rendered.contains("You are the profile `\(profile)`"))
    }
    let jarvis = try #require(SkillLibrary.render(skill, forProfile: "grok-jarvis", managerTemplate: template))
    #expect(jarvis.contains(modelRecipe), "the rendered skill carries the recipe byte for byte")
    #expect(SkillLibrary.render(skill, forProfile: "x", managerTemplate: nil) == nil, "no manager text, no skill")
}

@Test func skillResourcesShipInEveryBuild() throws {
    let package = try String(contentsOfFile: "Package.swift", encoding: .utf8)
    #expect(package.contains(#".copy("Resources/Skills")"#))
    let build = try String(contentsOfFile: "scripts/build.sh", encoding: .utf8)
    #expect(build.contains(#"cp -R Resources/Skills "$BUILD_DIR/AgentApp.resources/Skills""#))
    let release = try String(contentsOfFile: "scripts/package-release.sh", encoding: .utf8)
    #expect(release.contains(#"Resources/Skills" "$APP_DIR/Contents/Resources/Skills""#))
    // Path candidates mirror BotManagerText's, so the installed app, the SwiftPM bundle and the checkout all resolve.
    #expect(SkillLibrary.defaultCandidates.map(\.lastPathComponent).allSatisfy { $0 == "Skills" })
    #expect(SkillLibrary.defaultCandidates.count == BotManagerText.defaultCandidates.count)
    let built = SkillLibrary.defaultCandidates.filter { $0.path.contains("AgentApp_AgentApp.bundle") || $0.path.contains("AgentApp.resources") }
    #expect(built.contains { FileManager.default.fileExists(atPath: $0.appending(path: "swarmhub-manager/SKILL.md").path) }
            || FileManager.default.fileExists(atPath: "Resources/Skills/swarmhub-manager/SKILL.md"))
}

@Test func versionsAndStates() {
    #expect(SkillVersion("1.2.3")! < SkillVersion("1.10.0")! && SkillVersion("1.2") == nil && SkillVersion("v1.2.3") == nil && SkillVersion("1.2.x") == nil)
    let bundled = SkillVersion("1.1.0")!
    #expect(SkillLibrary.state(installed: nil, bundled: bundled) == .missing)
    #expect(SkillLibrary.state(installed: "1.0.0", bundled: bundled) == .outdated(installed: "1.0.0"))
    #expect(SkillLibrary.state(installed: "garbage", bundled: bundled) == .outdated(installed: "garbage"))
    #expect(SkillLibrary.state(installed: "1.1.0", bundled: bundled) == .current)
    #expect(SkillLibrary.installPath("swarmhub-manager", profile: "default") == "~/.hermes/skills/swarmhub/swarmhub-manager")
    #expect(SkillLibrary.installPath("swarmhub-manager", profile: "grok-jarvis") == "~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-manager")
}

@Test func skillsInstalledBlockParsesNamesAndVersionsOnly() {
    let reply = "Installed.\n```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"grok-jarvis\",\"skills\":[{\"name\":\"swarmhub-manager\",\"version\":\"1.0.0\",\"content\":\"rm -rf /\"},{\"name\":\"../x\",\"version\":\"1.0.0\"},{\"name\":\"y\",\"version\":\"one\"}]}\n```"
    #expect(SwarmhubBlock.ops(in: reply) == [.skillsInstalled(bot: "grok-jarvis", skills: [.init(name: "swarmhub-manager", version: "1.0.0")])])
    #expect(SwarmhubBlock.ops(in: "```swarmhub\n{\"op\":\"skills_installed\",\"bot\":\"bad name\",\"skills\":[]}\n```") == [])
}

/// The built binary finds both resources from its own folder, whichever SwiftPM bundle layout the toolchain used.
@Test func builtBundleLayoutsResolve() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "p27-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let resources = folder.appending(path: "AgentApp_AgentApp.bundle/Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources.appending(path: "Skills/swarmhub-manager"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources.appending(path: "BotManager"), withIntermediateDirectories: true)
    try "manager {{MANAGER}}".write(to: resources.appending(path: "BotManager/manager-hermes.md"), atomically: true, encoding: .utf8)
    try "---\nname: swarmhub-manager\nversion: 2.0.0\n---\nx".write(to: resources.appending(path: "Skills/swarmhub-manager/SKILL.md"), atomically: true, encoding: .utf8)
    let executable = folder.appending(path: "AgentApp")
    let managerCandidates = [executable.deletingLastPathComponent().appending(path: "AgentApp_AgentApp.bundle/Contents/Resources/\(BotManagerText.resourcePath)")]
    #expect(BotManagerText.defaultCandidates.contains { $0.path.hasSuffix("AgentApp_AgentApp.bundle/Contents/Resources/BotManager/manager-hermes.md") })
    #expect(BotManagerText.template(candidates: managerCandidates) == "manager {{MANAGER}}")
    let skillFolder = SkillLibrary.folder(candidates: managerCandidates.map { $0.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Skills") })
    #expect(SkillLibrary.bundled(in: skillFolder).map(\.version.description) == ["2.0.0"])
}

/// P56 2: the manager skill tells a bot its heartbeat is the one routine SwarmHub manages, to edit and never duplicate.
@Test func theManagerSkillTellsBotsToEditTheirOneHeartbeatRoutine() throws {
    let skill = try #require(SkillLibrary.bundled().first { $0.name == SkillLibrary.managerSkill })
    #expect(skill.version == SkillVersion("1.3.0"))
    #expect(skill.template.contains("version: 1.3.0") && skill.template.contains("\n## Heartbeat\n"))
    for phrase in ["routine SwarmHub manages", "swarmhub-heartbeat", "never create a second heartbeat routine", "deliver: bot-chat:<profile>", "say what changed", "SwarmHub reads it back"] {
        #expect(skill.template.contains(phrase), "\(phrase)")
    }
    #expect(SkillLibrary.state(installed: "1.2.0", bundled: skill.version, installedVariant: nil, wantedVariant: nil) == .outdated(installed: "1.2.0"),
            "a manager with 1.2.0 is offered the update")
}

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

@Test func managerTextCarriesTheModelRecipeWithinItsBudget() throws {
    let template = try #require(BotManagerText.template())
    #expect(template.utf8.count <= 4096, "manager-hermes.md is \(template.utf8.count) bytes")
    #expect(template.contains(#"hermes -p "$N" config set model.default "$MODEL""#) && template.contains(#"config set model.provider "$PROV""#))
    #expect(template.contains("nohup sh -c") && template.contains("~/.hermes/swarmhub-model.log") && template.contains("echo DONE"))
    #expect(template.contains("default $(ls ~/.hermes/profiles | grep -E '^[a-z0-9][a-z0-9_-]*$')"))
    #expect(template.contains("delegation.model") && template.contains("delegation.provider") && template.contains("ask first"))
    for profile in ["default", "grok-jarvis"] {
        let filled = BotManagerText.filled(template, managerProfile: profile)
        #expect(!filled.contains("{{"), "\(profile)")
    }
    // No command that reads a secret out: the only .env read feeds the HMAC directly; nothing cats/echoes keys or config.
    let commands = template.lowercased()
    for forbidden in ["cat ~/.hermes/.env", "cat \"$p/.env\"", "echo $mk", "echo $k", "printenv", "env |", "cat ~/.hermes/config.yaml", "security "] {
        #expect(!commands.contains(forbidden), "\(forbidden)")
    }
}

// MARK: Library

@Test func libraryListsTheBundledManagerSkill() throws {
    let skills = SkillLibrary.bundled()
    #expect(skills.map(\.name) == ["swarmhub-manager"])
    let skill = try #require(skills.first)
    #expect(skill.version >= SkillVersion("1.0.0")!)
    let fields = SkillLibrary.frontmatter(skill.template)
    #expect(fields["name"] == "swarmhub-manager" && fields["version"] == skill.version.description)
    #expect(skill.template.contains("metadata:\n  swarmhub:\n    source: swarmhub"))
}

@Test func renderedSkillIsTheManagerTextForThatProfile() throws {
    let skill = try #require(SkillLibrary.bundled().first)
    let template = try #require(BotManagerText.template())
    for profile in ["default", "grok-jarvis"] {
        let rendered = try #require(SkillLibrary.render(skill, forProfile: profile, managerTemplate: template))
        #expect(!rendered.contains("{{"), "\(profile)")
        let fields = SkillLibrary.frontmatter(rendered)
        #expect(fields["name"] == "swarmhub-manager" && SkillVersion(fields["version"] ?? "") == skill.version)
        let description = try #require(fields["description"])
        #expect(description.hasPrefix("Use when") && description.contains("models") && SkillLibrary.advertisedVersion(in: description) == skill.version.description)
        // The body is exactly the manager text rendered for this profile (one source of truth).
        let manager = BotManagerText.filled(template, managerProfile: profile).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rendered.hasSuffix(manager + "\n"))
        #expect(rendered.contains("You are the profile `\(profile)`"))
    }
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

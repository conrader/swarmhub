import Foundation
import Testing
@testable import AgentApp

// P34 D1–D3: the bundled swarmhub-messages skill (rendered per bot with its own name as the sender) and the bot-msg
// shell test run under /bin/sh and /bin/dash against a stub gateway. Synthetic only.

private func messagesSkill() throws -> BundledSkill { try #require(SkillLibrary.bundled().first { $0.name == "swarmhub-messages" }) }
private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

@Test func messagesSkillShipsWithItsScript() throws {
    let skill = try messagesSkill()
    #expect(skill.version == SkillVersion("1.1.0")!)
    let fields = SkillLibrary.frontmatter(skill.template)
    #expect(fields["author"] == "SwarmHub" && skill.template.contains("metadata:\n  swarmhub:\n    source: swarmhub"))
    let description = try #require(fields["description"])
    #expect(description.hasPrefix("Use for any message to another bot") && description.contains("supersedes `hermes -p … chat` and peer commands")
            && description.hasSuffix("Installed by SwarmHub, v{{VERSION}}."))
    let script = try #require(skill.files.first { $0.path == "scripts/bot-msg" })
    #expect(skill.files.map(\.path) == ["scripts/bot-msg"] && script.isExecutable && script.content.hasPrefix("#!/bin/sh\n"))
    #expect(script.content.range(of: #"(?m)(^|[;&|(]|then|do)\s*(timeout|flock|setsid|local|jq)\s"#, options: .regularExpression) == nil)
    // (awk's own `function` lines are fine; a shell `function name` at the start of a line is not.)
    #expect(script.content.range(of: #"(?m)^function "#, options: .regularExpression) == nil)
    for banned in ["[[ ", "<(", "$'", "pipefail", "#!/bin/bash", "declare ", "source ", "SWARMHUB_EOF"] {
        #expect(!script.content.contains(banned), "\(banned)")
    }
    // The key reaches curl on stdin only.
    #expect(script.content.contains("curl -sS -K -") && !script.content.contains("-H \"Authorization"))
    #expect(SkillLibrary.variant(of: skill, codingOrder: .codexOnly) == nil)
}

@Test func renderedMessagesSkillSendsAsThisBot() throws {
    let skill = try messagesSkill()
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "grok-jarvis", managerTemplate: nil, codingOrder: .standard))
    #expect(!rendered.contains("{{"))
    #expect(rendered.contains("~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-messages/scripts/bot-msg --from grok-jarvis --to <bot> -- \"<message>\""))
    #expect(rendered.contains("[Message from <bot> via SwarmHub]") && rendered.contains("answer it right there in the same thread"))
    #expect(rendered.contains("--no-wait") && rendered.contains("Report what the other bot said"))
    // P42 9: a late reply arrives as a new message; it is never answered back or sent on.
    #expect(rendered.contains("[Reply from <bot> via SwarmHub]") && rendered.contains("Do not answer\nit back to that bot"))
    #expect(SkillLibrary.advertisedVersion(in: SkillLibrary.frontmatter(rendered)["description"] ?? "") == "1.1.0")
    let main = try #require(SkillLibrary.render(skill, forProfile: "default", managerTemplate: nil, codingOrder: .standard))
    #expect(main.contains("~/.hermes/skills/swarmhub/swarmhub-messages/scripts/bot-msg --from default --to"))
}

/// `Tests/Scripts/bot-msg-test.sh` under each shell present: a stub gateway, a temp HOME, every case must pass.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func botMsgShellTestPasses(_ shell: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: shell), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = [repoRoot.appending(path: "Tests/Scripts/bot-msg-test.sh").path, repoRoot.appending(path: "Resources/Skills/swarmhub-messages/scripts/bot-msg").path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "BOT_MSG_SH": shell]
    let (status, output) = try await runToEnd(process)
    #expect(status == 0, "\(shell):\n\(output)")
    #expect(output.contains("bot-msg tests under \(shell): 14 passed, 0 failed"), "\(output)")
    #expect(!output.contains("FAIL"), "\(output)")
}

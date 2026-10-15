import Foundation
import Testing
@testable import AgentApp

// P36: the bundled swarmhub-feedback skill (rendered per bot with its own name) and the swarmhub-report shell test run
// under /bin/sh and /bin/dash in a temp HOME. Synthetic only.

private func feedbackSkill() throws -> BundledSkill { try #require(SkillLibrary.bundled().first { $0.name == "swarmhub-feedback" }) }
private var repoRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

@Test func feedbackSkillShipsWithItsScript() throws {
    let skill = try feedbackSkill()
    #expect(skill.version == SkillVersion("1.0.0")!)
    let fields = SkillLibrary.frontmatter(skill.template)
    #expect(fields["author"] == "SwarmHub" && skill.template.contains("metadata:\n  swarmhub:\n    source: swarmhub"))
    let description = try #require(fields["description"])
    #expect(description.hasPrefix("Use to report a bug or a feature request to SwarmHub's makers") && description.hasSuffix("Installed by SwarmHub, v{{VERSION}}."))
    let script = try #require(skill.files.first { $0.path == "scripts/swarmhub-report" })
    #expect(skill.files.map(\.path) == ["scripts/swarmhub-report"] && script.isExecutable && script.content.hasPrefix("#!/bin/sh\n"))
    #expect(script.content.range(of: #"(?m)(^|[;&|(]|then|do)\s*(timeout|flock|setsid|local|jq)\s"#, options: .regularExpression) == nil)
    // (awk's own `function` lines are fine; a shell `function name` at the start of a line is not.)
    #expect(script.content.range(of: #"(?m)^function "#, options: .regularExpression) == nil)
    for banned in ["[[ ", "<(", "$'", "pipefail", "#!/bin/bash", "declare ", "source ", "SWARMHUB_EOF"] {
        #expect(!script.content.contains(banned), "\(banned)")
    }
    #expect(SkillLibrary.variant(of: skill, codingOrder: .codexOnly) == nil)
}

@Test func renderedFeedbackSkillReportsAsThisBot() throws {
    let skill = try feedbackSkill()
    let rendered = try #require(SkillLibrary.render(skill, forProfile: "grok-jarvis", managerTemplate: nil, codingOrder: .standard))
    #expect(!rendered.contains("{{"))
    #expect(rendered.contains("~/.hermes/profiles/grok-jarvis/skills/swarmhub/swarmhub-feedback/scripts/swarmhub-report --bot grok-jarvis --kind"))
    #expect(rendered.contains("SwarmHub's Reports") && rendered.contains("nothing is sent until they press Send"))
    #expect(rendered.contains("Never include secrets") && rendered.contains("```swarmhub"))
    #expect(SkillLibrary.advertisedVersion(in: SkillLibrary.frontmatter(rendered)["description"] ?? "") == "1.0.0")
    let main = try #require(SkillLibrary.render(skill, forProfile: "default", managerTemplate: nil, codingOrder: .standard))
    #expect(main.contains("~/.hermes/skills/swarmhub/swarmhub-feedback/scripts/swarmhub-report --bot default --kind"))
}

/// `Tests/Scripts/swarmhub-report-test.sh` under each shell present: a temp HOME per case, every case must pass.
@Test(arguments: ["/bin/sh", "/bin/dash"]) func swarmhubReportShellTestPasses(_ shell: String) async throws {
    guard FileManager.default.isExecutableFile(atPath: shell), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = [repoRoot.appending(path: "Tests/Scripts/swarmhub-report-test.sh").path,
                         repoRoot.appending(path: "Resources/Skills/swarmhub-feedback/scripts/swarmhub-report").path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path, "TMPDIR": FileManager.default.temporaryDirectory.path, "REPORT_SH": shell]
    let (status, output) = try await runToEnd(process)
    #expect(status == 0, "\(shell):\n\(output)")
    #expect(output.contains("swarmhub-report tests under \(shell): 22 passed, 0 failed"), "\(output)")
    #expect(!output.contains("FAIL"), "\(output)")
}

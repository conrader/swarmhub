import Foundation
import Testing
@testable import AgentApp

// P0d (CORE-PHASES.md): golden renders of every bundled skill for sample profiles and every coding order, in
// Tests/Fixtures/release-bundles/renders/. The box updater's Python port (Resources/Updater/swarmhub_update/render.py)
// must match them byte for byte (Tests/Updater/test_render.py). This test fails when the goldens drift from
// SkillLibrary.render or are still the provisional Python-written set (a PROVISIONAL marker). To (re)write them from
// Swift: `SWARMHUB_WRITE_RENDERS=1 swift test --filter RenderGoldenTests`, then review `git diff` and commit.
// Layout: <skill>/<profile>/<coding order, commas as dashes>/SKILL.md, or `any-order` for a skill that renders no
// coding order (every order must render the same text), and <skill>/<profile>/files/references/<recipe>.md.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let rendersFolder = repoRoot.appending(path: "Tests/Fixtures/release-bundles/renders", directoryHint: .isDirectory)
/// Same lists as Tests/Updater/test_render.py.
private let goldenProfiles = ["default", "grok-jarvis", "coder_2"]
private let anyOrder = "any-order"
private let notGoldens: Set<String> = ["README.md", "PROVISIONAL"]

/// Every golden path (relative to the renders folder) with the bytes SkillLibrary renders today from the checkout's
/// Resources (not whatever bundle copy the test binary would find first).
private func currentRenders() throws -> [String: Data] {
    let resources = repoRoot.appending(path: "Resources", directoryHint: .isDirectory)
    let managerTemplate = try #require(BotManagerText.template(candidates: [resources.appending(path: BotManagerText.resourcePath)]))
    let references = try BotManagerText.Recipe.allCases.map { recipe in
        SkillFile(path: recipe.referencePath, content: try #require(BotManagerText.template(candidates: [resources.appending(path: recipe.resourcePath)])))
    }
    let skills = SkillLibrary.bundled(in: resources.appending(path: SkillLibrary.resourceFolder, directoryHint: .isDirectory), managerReferences: references)
    #expect(skills.map(\.name) == ["swarmhub-coding", "swarmhub-feedback", "swarmhub-manager", "swarmhub-messages"], "all four skills (a stray __pycache__ in a skill folder makes bundled() skip it; delete it)")
    var renders: [String: Data] = [:]
    for skill in skills {
        for profile in goldenProfiles {
            for order in CodingOrder.allCases {
                let text = try #require(SkillLibrary.render(skill, forProfile: profile, managerTemplate: managerTemplate, codingOrder: order))
                let slug = SkillLibrary.variant(of: skill, codingOrder: order).map { $0.replacingOccurrences(of: ",", with: "-") } ?? anyOrder
                let path = "\(skill.name)/\(profile)/\(slug)/SKILL.md"
                if let earlier = renders[path] { #expect(earlier == Data(text.utf8), "\(path) differs between coding orders") }
                renders[path] = Data(text.utf8)
            }
            for file in skill.files {
                let rendered = SkillLibrary.render(file, forProfile: profile)
                if file.path.hasPrefix("references/") {
                    renders["\(skill.name)/\(profile)/files/\(file.path)"] = Data(rendered.content.utf8)
                } else {
                    #expect(rendered == file, "\(skill.name)/\(file.path) ships as is (render.py assumes so)")
                }
            }
        }
    }
    return renders
}

/// The goldens in the folder: every regular file but the README and the PROVISIONAL marker.
private func goldensOnDisk() -> [String: Data] {
    let base = rendersFolder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    guard let walker = FileManager.default.enumerator(at: rendersFolder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
    var files: [String: Data] = [:]
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard full.hasPrefix(base) else { continue }
        let path = String(full.dropFirst(base.count))
        guard !notGoldens.contains(path) else { continue }
        files[path] = (try? Data(contentsOf: url)) ?? Data()
    }
    return files
}

/// Replaces everything in the folder but the README (the PROVISIONAL marker included) with `renders`.
private func writeGoldens(_ renders: [String: Data]) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: rendersFolder, withIntermediateDirectories: true)
    for name in try manager.contentsOfDirectory(atPath: rendersFolder.path) where name != "README.md" {
        try manager.removeItem(at: rendersFolder.appending(path: name))
    }
    for (path, data) in renders {
        let url = rendersFolder.appending(path: path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

@Test func goldenRendersMatchSkillLibrary() throws {
    let renders = try currentRenders()
    #expect(renders.count == 36, "3 profiles × (5 coding orders + 3 other SKILL.md + 4 references)")
    if ProcessInfo.processInfo.environment["SWARMHUB_WRITE_RENDERS"] == "1" { try writeGoldens(renders) }
    let disk = goldensOnDisk()
    #expect(Set(renders.keys).subtracting(disk.keys).sorted() == [], "goldens missing; rerun with SWARMHUB_WRITE_RENDERS=1")
    #expect(Set(disk.keys).subtracting(renders.keys).sorted() == [], "stale goldens; rerun with SWARMHUB_WRITE_RENDERS=1")
    for (path, data) in renders.sorted(by: { $0.key < $1.key }) where disk[path] != nil {
        #expect(disk[path] == data, "\(path) drifted from SkillLibrary.render; rerun with SWARMHUB_WRITE_RENDERS=1")
    }
    let marker = rendersFolder.appending(path: "PROVISIONAL").path
    #expect(!FileManager.default.fileExists(atPath: marker), "goldens are the provisional Python-written set; rerun with SWARMHUB_WRITE_RENDERS=1 to make them Swift's")
}

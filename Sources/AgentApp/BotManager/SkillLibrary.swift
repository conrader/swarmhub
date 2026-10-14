import Foundation
import os

/// P27: one skill SwarmHub authors and versions (`Resources/Skills/<name>/SKILL.md`) and installs into a bot's own
/// profile as an ordinary Hermes skill. Hermes itself is never changed; the file is what a user would install by hand.
struct BundledSkill: Equatable, Sendable {
    let name: String
    let version: SkillVersion
    /// The SKILL.md template: frontmatter plus `{{VERSION}}` and, for `swarmhub-manager`, `{{MANAGER_TEXT}}`.
    let template: String
    /// P31: every other file of the skill's folder (e.g. `scripts/code-job`), written next to SKILL.md as is.
    var files: [SkillFile] = []
}

/// P31: one extra file of a bundled skill, its path relative to the skill's folder.
struct SkillFile: Equatable, Sendable {
    let path: String
    let content: String
    /// Files under `scripts/` are installed `chmod 755`.
    var isExecutable: Bool { path.hasPrefix("scripts/") }
}

/// A semver `major.minor.patch`; anything else does not parse.
struct SkillVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}

/// A bot's copy of one bundled skill, compared with what this build ships.
enum SkillInstallState: Equatable {
    case missing, outdated(installed: String), current
    var needsAction: Bool { self != .current }
}

enum SkillLibrary {
    static let managerSkill = "swarmhub-manager"
    static let resourceFolder = "Skills"
    /// Hermes lists a skill's category from its folder: everything SwarmHub installs lives under `skills/swarmhub/`.
    static let category = "swarmhub"

    /// The installed app's Resources, the SwiftPM bundle next to the binary, or the checkout (tests); first that exists.
    static func folder(candidates: [URL] = defaultCandidates) -> URL? {
        candidates.first { (try? $0.checkResourceIsReachable()) == true }
    }

    static var defaultCandidates: [URL] {
        BotManagerText.defaultCandidates.map {
            $0.deletingLastPathComponent().deletingLastPathComponent().appending(path: resourceFolder, directoryHint: .isDirectory)
        }
    }

    /// Every bundled skill, sorted by name; a folder without a valid SKILL.md (name matches, semver version) is skipped.
    static func bundled(in folder: URL? = folder()) -> [BundledSkill] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name in
            guard let text = try? String(contentsOf: folder.appending(path: "\(name)/SKILL.md"), encoding: .utf8) else { return nil }
            let fields = frontmatter(text)
            guard fields["name"] == name, HermesKeyPaste.isValidProfileName(name), let version = fields["version"].flatMap(SkillVersion.init),
                  let files = extraFiles(in: folder.appending(path: name, directoryHint: .isDirectory)) else { return nil }
            return BundledSkill(name: name, version: version, template: text, files: files)
        }
    }

    /// P31: every regular file of a skill's folder besides the top SKILL.md, sorted by path (dot files skipped). Nil, so
    /// the skill is not offered, when one is not UTF-8 text or its path has anything but letters, digits, `.`, `_`, `-`.
    static func extraFiles(in folder: URL) -> [SkillFile]? {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [SkillFile] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { return nil }
            let path = String(full.dropFirst(base.count))
            guard path != "SKILL.md" else { continue }
            guard isSafeRelativePath(path), let content = try? String(contentsOf: url, encoding: .utf8) else {
                SwarmhubBlock.log.error("Skill file \(path, privacy: .public) is not installable; skill skipped")
                return nil
            }
            files.append(SkillFile(path: path, content: content))
        }
        return files.sorted { $0.path < $1.path }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
    }

    /// The top-level `key: value` lines of a leading `---` block (quotes trimmed); nested keys are not flattened.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var fields: [String: String] = [:]
        for line in lines[1..<end] where !line.hasPrefix(" ") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[String(line[..<colon])] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return fields
    }

    /// The SKILL.md written into `profile`: the version filled in and, for `swarmhub-manager`, the manager text rendered
    /// for that profile (`manager-hermes.md` stays the one source of truth). Nil when a needed template is missing.
    static func render(_ skill: BundledSkill, forProfile profile: String, managerTemplate: String?) -> String? {
        var text = skill.template.replacingOccurrences(of: "{{VERSION}}", with: skill.version.description)
        if text.contains("{{MANAGER_TEXT}}") {
            guard let managerTemplate else { return nil }
            let manager = BotManagerText.filled(managerTemplate, managerProfile: profile).trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "{{MANAGER_TEXT}}", with: manager)
        }
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// `~/.hermes/skills` for `default`, else `~/.hermes/profiles/<profile>/skills`.
    static func skillsRoot(forProfile profile: String) -> String {
        profile == "default" ? "~/.hermes/skills" : "~/.hermes/profiles/\(profile)/skills"
    }

    static func installPath(_ skill: String, profile: String) -> String { "\(skillsRoot(forProfile: profile))/\(category)/\(skill)" }

    /// A bot's copy against the bundled one: absent, older (or unreadable), or current.
    static func state(installed: String?, bundled: SkillVersion) -> SkillInstallState {
        guard let installed else { return .missing }
        guard let version = SkillVersion(installed), version >= bundled else { return .outdated(installed: installed) }
        return .current
    }

    /// The version an installed SKILL.md advertises in its description ("Installed by SwarmHub, v1.2.3"), since stock
    /// `GET /v1/skills` lists only name, description and category.
    static func advertisedVersion(in description: String) -> String? {
        guard let range = description.range(of: #"SwarmHub, v\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return String(description[range].dropFirst("SwarmHub, v".count))
    }
}

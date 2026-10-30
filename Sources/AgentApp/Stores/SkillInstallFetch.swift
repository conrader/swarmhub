import CryptoKit
import Foundation

/// uxfix1-e2e: a skill's large files must not travel through the model. A legacy install asked the manager to retype
/// every file as a heredoc; `swarmhub-messages` is ~290 KB of scripts, which the model does not reproduce (live run,
/// 27 Oct: "its source tree was incomplete" on every bot of the batch). A clean release build knows the commit it was
/// built from (`SOURCE.txt`), and the repository is public, so the box fetches each file that SwarmHub ships unchanged
/// from that exact commit and checks the whole tree's digest before writing anything. The model types one short
/// command. SKILL.md and any file rendered for the bot (profile names, recipes) still go as heredocs; a development or
/// dirty build has no commit to point at and writes everything as before.
enum SkillFetch {
    static let repository = "conrader/swarmhub"
    static let failure = "SWARMHUB_FETCH_FAILED"
    static let end = "SWARMHUB_FETCH"

    /// argv: base URL (ends in `/`), destination folder, tree digest, comma-separated paths. Verifies before writing.
    static let script = """
    import hashlib, os, sys, urllib.request
    base, dst, want, names = sys.argv[1:5]
    tree, files = hashlib.sha256(), []
    try:
        for path in names.split(','):
            data = urllib.request.urlopen(base + path, timeout=60).read()
            tree.update(path.encode() + b'\\0' + hashlib.sha256(data).digest())
            files.append((path, data))
    except Exception as error:
        sys.exit('\(failure) ' + dst + ' ' + str(error))
    if tree.hexdigest() != want:
        sys.exit('\(failure) ' + dst + ' digest mismatch')
    for path, data in files:
        target = os.path.join(os.path.expanduser(dst), path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target + '.swarmhub-tmp', 'wb') as out:
            out.write(data)
        os.replace(target + '.swarmhub-tmp', target)
    print('fetched', len(files), 'files into', dst)

    """

    struct Plan: Equatable { let base: String, destination: String, digest: String, names: [String] }

    /// The `scripts/` files of `rendered` that `skill` ships byte for byte (not rendered for this bot), fetched from
    /// `sourceSHA`; nil without a commit or when nothing qualifies. SKILL.md and the manager's references (which live
    /// elsewhere in the repository) are never fetched.
    static func plan(skill: BundledSkill, rendered: [SkillFile], folder: String, sourceSHA: String?) -> Plan? {
        guard let sha = sourceSHA, sha.count == 40, sha.allSatisfy(\.isHexDigit), safe(folder) else { return nil }
        var names: [String] = [], digest = SHA256()
        for file in rendered where file.path.hasPrefix("scripts/") && file.content.hasSuffix("\n") && safe(file.path) && !file.path.contains(",") {
            guard skill.files.first(where: { $0.path == file.path })?.content == file.content else { continue }
            names.append(file.path)
            digest.update(data: Data(file.path.utf8) + Data([0]) + Data(SHA256.hash(data: Data(file.content.utf8))))
        }
        guard !names.isEmpty else { return nil }
        return Plan(base: "https://raw.githubusercontent.com/\(repository)/\(sha.lowercased())/Resources/Skills/\(skill.name)/", destination: folder,
                    digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), names: names)
    }

    static func command(_ plan: Plan) -> String {
        let args = [plan.base, plan.destination, plan.digest, plan.names.joined(separator: ",")]
        return "python3 - " + args.map { "'\($0)'" }.joined(separator: " ") + " <<'\(end)'\n" + script + end
    }

    /// The commit a clean packaged build was made from; nil for development and dirty builds.
    static func buildCommit(_ info: AppBuildInfo = .current()) -> String? { info.dirty ? nil : info.sourceSHA }

    private static func safe(_ text: String) -> Bool { !text.isEmpty && !text.contains("'") && !text.contains("\n") && text.allSatisfy(\.isASCII) }
}

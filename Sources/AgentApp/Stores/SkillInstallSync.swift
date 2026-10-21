import CryptoKit
import Foundation

/// Speed (0.6.4): a skill another profile on the box already holds is copied from it instead of travelling as heredocs
/// the manager has to type back out (swarmhub-messages alone is ~170 KB per profile). Only SKILL.md differs between
/// profiles (`{{BOT}}`, `{{SKILL_DIR}}`); the app checks that swapping the source profile's names for this one's turns
/// the source rendering into exactly this profile's, and the box refuses the copy unless the result hashes to the
/// digest computed here, writing nothing. So a stale, edited or missing source never lands; that profile's skill fails.
enum SkillSync {
    static let end = "SWARMHUB_SYNC"
    static let failure = "SWARMHUB_SYNC_FAILED"

    /// argv: source folder, destination folder, digest, comma-separated names (`*`: apply the substitutions), then
    /// substitution pairs. Verifies everything before writing; SKILL.md (the advertised version) is written last.
    static let script = """
    import hashlib, os, sys
    src, dst, want, names, *subs = sys.argv[1:]
    pairs = list(zip(subs[0::2], subs[1::2]))
    tree, files = hashlib.sha256(), []
    for name in names.split(','):
        path = name.rstrip('*')
        data = open(os.path.join(os.path.expanduser(src), path), 'rb').read()
        for old, new in (pairs if name.endswith('*') else []):
            data = data.replace(old.encode(), new.encode())
        tree.update(path.encode() + b'\\0' + hashlib.sha256(data).digest())
        files.append((path, data))
    if tree.hexdigest() != want:
        sys.exit('\(failure) ' + dst)
    for path, data in sorted(files, key=lambda item: item[0] == 'SKILL.md'):
        target = os.path.join(os.path.expanduser(dst), path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target + '.swarmhub-tmp', 'wb') as out:
            out.write(data)
        os.replace(target + '.swarmhub-tmp', target)

    """

    struct Plan: Equatable {
        let source: String, destination: String, digest: String
        let names: [String]
        let substitutions: [[String]]
    }

    /// The copy of `expected` (this profile's files, as the heredocs would write them) from `source` (the source
    /// profile's), or nil when some file cannot be derived that way; the caller then writes heredocs as before.
    static func plan(expected: [SkillFile], source: [SkillFile], sourceFolder: String, folder: String,
                     substitutions: [(String, String)]) -> Plan? {
        guard !expected.isEmpty, expected.count == source.count, !substitutions.isEmpty,
              ([sourceFolder, folder] + substitutions.flatMap { [$0.0, $0.1] }).allSatisfy(safe) else { return nil }
        var names: [String] = [], digest = SHA256()
        for file in expected {
            guard let from = source.first(where: { $0.path == file.path }), safe(file.path), !file.path.contains(",") else { return nil }
            let want = written(file.content), have = written(from.content)
            let swapped = substitutions.reduce(have) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .literal) }
            if have == want { names.append(file.path) } else if swapped == want { names.append(file.path + "*") } else { return nil }
            digest.update(data: Data(file.path.utf8) + Data([0]) + Data(SHA256.hash(data: Data(want.utf8))))
        }
        return Plan(source: sourceFolder, destination: folder, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                    names: names, substitutions: substitutions.map { [$0.0, $0.1] })
    }

    static func command(_ plan: Plan) -> String {
        let args = [plan.source, plan.destination, plan.digest, plan.names.joined(separator: ",")] + plan.substitutions.flatMap { $0 }
        return "python3 - " + args.map { "'\($0)'" }.joined(separator: " ") + " <<'\(end)'\n" + script + end
    }

    /// The bytes a heredoc writes (a final newline added where missing).
    static func written(_ content: String) -> String { content.hasSuffix("\n") ? content : content + "\n" }

    /// Nothing that would need quoting inside single quotes, or that a substitution could not round-trip as UTF-8 bytes.
    private static func safe(_ text: String) -> Bool { !text.isEmpty && !text.contains("'") && !text.contains("\n") && text.allSatisfy(\.isASCII) }
}

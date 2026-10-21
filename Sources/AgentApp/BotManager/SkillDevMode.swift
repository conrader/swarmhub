import CryptoKit
import Foundation

/// Per-bot skill dev mode: while it is on, an install or update never overwrites a SwarmHub skill the bot changed on
/// its box. The box decides, on both install paths, with the same rule (`swarmhub_update/devmode.py` for the signed
/// updater, `guardScript` for the legacy shell install): a skill is kept when
/// `~/.hermes/swarmhub/dev-overrides/<profile>/<skill>/` exists, or when its live folder is neither the bundled copy
/// being installed (`contentDigest`) nor what SwarmHub last installed there (the baseline in
/// `~/.hermes/swarmhub/dev-baseline/<profile>/<skill>.sha256`, written after each dev-mode install). "Reset to bundled"
/// moves the live folder aside (`~/.hermes/swarmhub/dev-reset/<profile>/<skill>`, the previous reset's copy replaced),
/// writes exactly the bundled copy, removes the override folder and records the bundled digest. With dev mode off none
/// of this is sent and the install commands and profiles.json are byte-identical to before. Hermes is never changed.
enum SkillDevMode {
    /// What the box did with one skill of a dev-mode legacy install, from the turn's terminal output.
    enum Outcome: String, Equatable, Sendable { case kept = "KEPT", failed = "FAILED" }

    /// The legacy install's shell function: `check <profile> <skill> <bundled digest>` exits 0 (write) or 3 (keep);
    /// `record` stores the live folder's digest as the baseline; `clear` moves the live folder aside before a reset
    /// writes; `reset <profile> <skill> <bundled digest>` removes the override folder and, when the live folder is
    /// exactly the bundled copy, records that digest (else exits 4: no baseline, reported failed).
    static let functionHead = "swarmhub_dev() {\npython3 -I -B - \"$@\" <<'SWARMHUB_DEV'"
    static let functionTail = "SWARMHUB_DEV\n}"
    /// Around one guarded skill's commands ({profile}, {skill}, {bundled} filled in). The markers are split in the
    /// command so only the output, never an echoed command line, carries them.
    static let guardHead = "swarmhub_dev check {profile} {skill} {bundled}; case $? in\n0)"
    static let guardTail = "swarmhub_dev record {profile} {skill} ;;\n3) echo 'SWARMHUB_DEV_''KEPT:{profile}/{skill}' ;;\n*) echo 'SWARMHUB_DEV_''FAILED:{profile}/{skill}' ;;\nesac"
    /// Around a reset skill's commands: written into an empty folder, so files the bot added never survive a reset.
    static let resetHead = "swarmhub_dev clear {profile} {skill}; case $? in\n0)"
    static let resetTail = "swarmhub_dev reset {profile} {skill} {bundled} || echo 'SWARMHUB_DEV_''FAILED:{profile}/{skill}' ;;\n*) echo 'SWARMHUB_DEV_''FAILED:{profile}/{skill}' ;;\nesac"

    /// Stdlib Python 3 run by `swarmhub_dev`; its digest is `devmode.content_digest` (Tests/Updater/test_devmode.py runs
    /// this exact text). Paths follow `SkillLibrary.skillsRoot`: `~/.hermes`, profiles under `profiles/<name>`.
    static let guardScript = #"""
    import hashlib, os, re, shutil, stat, sys
    act, profile, skill = sys.argv[1:4]
    name = re.compile(r'[A-Za-z0-9_-]{1,64}')
    if not (name.fullmatch(profile) and name.fullmatch(skill)):
        sys.exit(2)
    root = os.path.expanduser('~/.hermes')
    home = root if profile == 'default' else os.path.join(root, 'profiles', profile)
    live = os.path.join(home, 'skills', 'swarmhub', skill)
    over = os.path.join(root, 'swarmhub', 'dev-overrides', profile, skill)
    base = os.path.join(root, 'swarmhub', 'dev-baseline', profile, skill + '.sha256')
    aside = os.path.join(root, 'swarmhub', 'dev-reset', profile, skill)


    def digest(folder):
        if os.path.islink(folder) or not os.path.isdir(folder):
            return None
        items = []
        for top, dirs, names in os.walk(folder):
            if any(os.path.islink(os.path.join(top, d)) for d in dirs):
                return None
            dirs[:] = [d for d in dirs if d != '__pycache__']
            for n in names:
                full = os.path.join(top, n)
                info = os.lstat(full)
                if not stat.S_ISREG(info.st_mode):
                    return None
                with open(full, 'rb') as handle:
                    data = handle.read()
                path = os.path.relpath(full, folder).replace(os.sep, '/').encode('utf-8')
                items.append((path, bool(info.st_mode & stat.S_IXUSR), data))
        hasher = hashlib.sha256()
        for path, executable, data in sorted(items, key=lambda item: item[0]):
            hasher.update(path + b'\0' + (b'x' if executable else b'-') + b'\0')
            hasher.update(hashlib.sha256(data).digest())
        return hasher.hexdigest()


    def remove(path, *parts):
        """Delete path (a link itself, never its target) only when its folder is root/parts, reached without links."""
        if os.path.lexists(path) and os.path.realpath(os.path.dirname(path)) == os.path.join(os.path.realpath(root), *parts):
            if os.path.islink(path) or not os.path.isdir(path):
                os.unlink(path)
            else:
                shutil.rmtree(path)


    if act == 'check':
        if os.path.lexists(over):
            sys.exit(3)
        if not os.path.lexists(live):
            sys.exit(0)
        now = digest(live)
        try:
            with open(base, 'rb') as handle:
                recorded = handle.read(128).decode('ascii').strip()
        except (OSError, UnicodeDecodeError):
            recorded = None
        sys.exit(0 if now is not None and now in (sys.argv[4], recorded) else 3)
    if act == 'clear':
        if os.path.lexists(live):
            os.makedirs(os.path.dirname(aside), 0o700, exist_ok=True)
            remove(aside, 'swarmhub', 'dev-reset', profile)
            if os.path.lexists(aside):
                sys.exit(4)
            shutil.move(live, aside)
        sys.exit(0)
    if act == 'reset':
        remove(over, 'swarmhub', 'dev-overrides', profile)
    if act in ('record', 'reset'):
        now = digest(live)
        if now is None or (act == 'reset' and now != sys.argv[4]):
            sys.exit(4)
        os.makedirs(os.path.dirname(base), 0o700, exist_ok=True)
        with open(base + '.tmp', 'w') as handle:
            handle.write(now + '\n')
        os.replace(base + '.tmp', base)
        sys.exit(0)
    sys.exit(2)
    """#

    static var functionDefinition: String { functionHead + "\n" + guardScript + "\n" + functionTail }

    /// One skill's install commands as dev mode sends them: guarded (written only when the box allows it, then its
    /// baseline recorded), or for a reset written into a cleared folder and followed by `reset`. Off and not reset:
    /// unchanged.
    static func wrap(_ body: [String], skill: String, profile: String, files: [SkillFile], devMode: Bool, reset: Bool) -> [String] {
        func fill(_ template: String) -> String {
            template.replacingOccurrences(of: "{profile}", with: profile).replacingOccurrences(of: "{skill}", with: skill)
                .replacingOccurrences(of: "{bundled}", with: contentDigest(files))
        }
        if reset { return [fill(resetHead)] + body + [fill(resetTail)] }
        guard devMode else { return body }
        return [fill(guardHead)] + body + [fill(guardTail)]
    }

    /// The digest of a folder holding exactly `files` as the legacy install writes them (a final newline added where
    /// missing; `scripts/` executable): each file's UTF-8 path, NUL, "x" or "-", NUL and the SHA-256 of its bytes, in
    /// path byte order. Equal to `devmode.content_digest` of that folder.
    static func contentDigest(_ files: [SkillFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            let text = file.content.hasSuffix("\n") ? file.content : file.content + "\n"
            hasher.update(data: Data(file.path.utf8) + Data([0]) + Data((file.isExecutable ? "x" : "-").utf8) + Data([0]))
            hasher.update(data: Data(SHA256.hash(data: Data(text.utf8))))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `\/` too: a terminal result that arrives as an object is re-encoded by JSONSerialization, which escapes slashes.
    private static let marker = try! NSRegularExpression(pattern: #"SWARMHUB_DEV_(KEPT|FAILED):([A-Za-z0-9_-]{1,64})\\?/([A-Za-z0-9_-]{1,64})"#)

    /// Every marker in a terminal result: the outcome and its "profile/skill".
    static func outcomes(in output: String) -> [(outcome: Outcome, key: String)] {
        marker.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match in
            guard let kind = Range(match.range(at: 1), in: output), let profile = Range(match.range(at: 2), in: output),
                  let skill = Range(match.range(at: 3), in: output), let outcome = Outcome(rawValue: String(output[kind])) else { return nil }
            return (outcome: outcome, key: "\(output[profile])/\(output[skill])")
        }
    }
}

import Foundation
import CryptoKit
import Darwin
import SwarmHubCore

/// P4b: a local service-layout snapshot, verified for the destination box. No extraction, loading or execution.
/// Bootstrap records are operator input, never discovered from chat or updater status. See STAGED-INSTALL.md.
enum StagedInstall {
    static let updater = "/usr/local/lib/swarmhub-update/bin/swarmhub-update"
    static let statusCommand = updater + " status"

    struct Box: Codable, Sendable {
        let source: URL
        let channel: String
        let installID: String
        let versions: [String: String]
        let checkpoint: Floor
    }

    struct Floor: Codable, Sendable {
        var keys: Int64 = 0
        var index: Int64 = 0
        var bundle: Int64 = 0
        var manifest: String? = nil
    }

    struct Profile: Codable, Sendable {
        let name: String
        let coding_order: String
        let skills: [String]
        /// Skill dev mode, and this request's Reset to bundled; nil (omitted from profiles.json) while unused.
        var dev_mode: Bool? = nil
        var reset: [String]? = nil
    }

    struct Package: Sendable {
        let files: [String: Data]
        let floor: Floor
        let versions: [String: String]
        let profiles: [Profile]
    }

    enum Failure: LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self { case .refused(let reason): "Staged skill install refused: \(reason)." }
        }
    }

    /// Until the key ceremony and embedded baseline land, only debug builds can use TEST roots.
    static var pins: Data? {
        #if DEBUG
        Data(#"{"roots":[{"ed25519_pub":"807f6bb1f2ddf5d198a8a1430dbae8b3019c6d229db14dc51dcb81ee3e059ee6","key_id":"TEST-root-1"},{"ed25519_pub":"18d0cd14e4bd58e6172780b8dcdcc1d1ab651c8985f8c980ebcf15c8d3a2226a","key_id":"TEST-root-2"}],"schema":"swarmhub/pins/1","threshold":1}"#.utf8)
        #else
        nil
        #endif
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func prepare(box: Box, saved: Floor, profiles: [Profile], now: String) throws -> Package {
        guard let pins, box.source.isFileURL, !box.installID.isEmpty,
              box.channel.range(of: #"\A[a-z0-9-]{1,32}\z"#, options: .regularExpression) != nil,
              !profiles.isEmpty, Set(profiles.map(\.name)).count == profiles.count,
              profiles.allSatisfy({ HermesKeyPaste.isValidProfileName($0.name) && CodingOrder(rawValue: $0.coding_order) != nil &&
                  !$0.skills.isEmpty && $0.skills.allSatisfy { SkillLibrary.isSafeRelativePath($0) && !$0.contains("/") } }) else {
            throw Failure.refused("operator configuration unavailable or invalid")
        }
        guard profiles.allSatisfy({ profile in Set(profile.reset ?? []).isSubset(of: Set(profile.skills)) }) else {
            throw Failure.refused("reset names a skill outside the profile's selection")
        }
        let floor = Floor(keys: max(box.checkpoint.keys, saved.keys), index: max(box.checkpoint.index, saved.index),
                          bundle: max(box.checkpoint.bundle, saved.bundle), manifest: saved.manifest)
        // Re-rendering a profile may resend the same bundle. Only the exact previously verified manifest may
        // reuse that floor, never another signed manifest at the same version.
        let repeatable = floor.bundle > 0 && floor.bundle == saved.bundle && saved.manifest != nil
        // The core verifier treats equality as already_applied before fetching a manifest or any blobs.
        // Permit verification of that version, then enforce the real floor and exact saved hash below.
        let verificationFloor = UpdateFloors(keysVersion: floor.keys, indexSequence: floor.index,
                                             bundleVersion: repeatable ? floor.bundle - 1 : floor.bundle)
        var files: [String: Data] = [:], versions: [String: String] = [:]
        func read(_ path: String, limit: Int) throws -> Data {
            let data = try readBytes(box.source.appendingPathComponent(path), limit: limit)
            files[path] = data
            return data
        }
        let keys = try read("keys.json", limit: 1_048_576)
        let index = try read("channels/\(box.channel).json", limit: 1_048_576)
        var manifestHash = ""
        let verified = try UpdateVerifier.verify(pins: pins, keys: keys, index: index, fetchManifest: { line in
            let raw = try read("bundles/\(line.bundleVersion).json", limit: 1_048_576)
            manifestHash = Self.digest(raw)
            return raw
        }, fetchBlob: { component in
            versions[component.name] = component.version
            return try read("blobs/sha256/" + component.sha256, limit: Int(component.size))
        }, channel: box.channel, now: now, floors: verificationFloor,
           consumer: UpdateConsumer(platform: "box", versions: box.versions), installID: box.installID)
        guard verified.verdict.verdict == "accept", let version = verified.verdict.bundleVersion,
              version > floor.bundle || (repeatable && version == floor.bundle && manifestHash == saved.manifest),
              profiles.allSatisfy({ Set($0.skills).isSubset(of: Set(verified.verdict.apply ?? [])) }) else {
            throw Failure.refused(verified.verdict.reason)
        }
        func number(_ data: Data, _ name: String) throws -> Int64 {
            guard case .object(let envelope) = try JCS.parse(data), case .object(let signed)? = envelope["signed"],
                  case .integer(let value)? = signed[name] else { throw Failure.refused("metadata") }
            return value
        }
        return Package(files: files, floor: Floor(keys: try number(keys, "version"), index: try number(index, "seq"),
                                                 bundle: version, manifest: manifestHash), versions: versions, profiles: profiles)
    }

    private static func readBytes(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.refused("source unavailable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else {
            throw Failure.refused("source size or type")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw Failure.refused("source size") }
        }
        return data
    }

    /// How the box script folds a request's profiles.json rows into the saved one (run verbatim by
    /// Tests/Updater/test_devmode_merge.py). A saved row keeps its skills (joined with the request's), and `dev_modes`
    /// (the app's skill dev mode toggle for every bot it knows on this box) sets or clears `dev_mode` on each saved row
    /// it names, so a request for one bot never drops another bot's dev mode. Rows it does not name are left as they were.
    static let profileMerge = #"""
    def merge_profiles(doc, incoming, dev_modes):
        rows = {row['name']: row for row in doc['profiles']}
        for row in incoming:
            old = rows.get(row['name'])
            if old is not None:
                row['skills'] = None if old.get('skills') is None else sorted(set(old['skills']) | set(row['skills']))
            rows[row['name']] = row
        for name, on in dev_modes.items():
            if name in rows and on:
                rows[name]['dev_mode'] = True
            elif name in rows:
                rows[name].pop('dev_mode', None)
        doc['profiles'] = list(rows.values())
        return doc
    """#

    /// Only identifiers and hashes travel through the model. The app uploads the bytes before starting its turn.
    /// `devModes`: skill dev mode per profile for the bots on this box (see `profileMerge`).
    static func command(_ transfer: StagedTransfer, profile: String, devModes: [String: Bool] = [:]) throws -> String {
        guard HermesKeyPaste.isValidProfileName(profile) else { throw Failure.refused("manager profile") }
        guard devModes.keys.allSatisfy(HermesKeyPaste.isValidProfileName) else { throw Failure.refused("dev mode profile") }
        let modes = "{" + devModes.sorted { $0.key < $1.key }.map { "'\($0.key)': \($0.value ? "True" : "False")" }
            .joined(separator: ", ") + "}"
        let prefix = transfer.prefix
        let hashes = transfer.hashes.map { "'\($0)'" }.joined(separator: ", ")
        let whole = transfer.sha256
        let managerProfile = profile
        return """
        python3 -I -B <<'SWARMHUB_STAGE'
        import base64, hashlib, json, os, pathlib, shutil, sqlite3, stat, subprocess, tempfile
        \(profileMerge)
        state = pathlib.Path(os.environ.get('XDG_STATE_HOME', str(pathlib.Path.home() / '.local/state'))) / 'swarmhub-update'
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder = pathlib.Path(tempfile.mkdtemp(prefix='mac-stage-', dir=state))
        try:
            home = pathlib.Path(os.environ.get('HERMES_HOME', str(pathlib.Path.home() / '.hermes')))
            profile = '\(managerProfile)'
            if profile != 'default' and home.name != profile:
                home = home / 'profiles' / profile
            # Snapshot raw DB/WAL bytes into updater state before opening SQLite, so even SQLite's
            # shared-memory bookkeeping cannot touch Hermes. Concurrent checkpoint races fail closed.
            snapshot = folder / 'carrier.db'
            budget = 64 * 1024 * 1024  # Combined DB/WAL limit, including concurrent growth.
            for source, target in [(home / 'state.db', snapshot), (home / 'state.db-wal', folder / 'carrier.db-wal')]:
                try:
                    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                except FileNotFoundError:
                    if source.name.endswith('-wal'):
                        continue
                    raise
                with os.fdopen(fd, 'rb') as src:
                    info = os.fstat(src.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_size > budget:
                        raise ValueError('carrier DB/WAL exceeds 64 MiB snapshot limit or is not a regular file')
                    with target.open('xb') as dst:
                        while True:
                            chunk = src.read(min(65536, budget + 1))
                            if not chunk:
                                break
                            budget -= len(chunk)
                            if budget < 0:
                                raise ValueError('carrier DB/WAL exceeds 64 MiB snapshot limit')
                            dst.write(chunk)
            db = sqlite3.connect(snapshot.as_uri() + '?mode=ro', uri=True, timeout=5)
            try:
                hashes = [\(hashes)]
                parts = []
                for i, expected in enumerate(hashes):
                    row = db.execute('SELECT system_prompt FROM sessions WHERE id = ?', ('\(prefix)' + str(i),)).fetchone()
                    if row is None or row[0] is None or len(row[0]) > 65536:
                        raise ValueError('missing or oversized transfer part')
                    part = base64.b64decode(row[0], validate=True)
                    if len(part) > 49152 or hashlib.sha256(part).hexdigest() != expected:
                        raise ValueError('transfer part hash mismatch')
                    parts.append(part)
            finally:
                db.close()
                for item in folder.glob('carrier.db*'):
                    item.unlink()
            payload = b''.join(parts)
            if hashlib.sha256(payload).hexdigest() != '\(whole)':
                raise ValueError('whole transfer hash mismatch')
            files = json.loads(payload)
            for name, encoded in files.items():
                if name.startswith('/') or any(p in ('', '.', '..') for p in name.split('/')):
                    raise ValueError('invalid staged path')
                target = folder / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(base64.b64decode(encoded, validate=True))
            incoming = json.loads((folder / 'profiles.json').read_bytes())
            prior = state / 'profiles.json'
            doc = json.loads(prior.read_bytes()) if prior.exists() else {'schema': 'swarmhub/profiles/1', 'profiles': []}
            doc = merge_profiles(doc, incoming, \(modes))
            (folder / 'profiles.json').write_text(json.dumps(doc))
            result = subprocess.run(['\(updater)', '--max-wait', '0', 'apply', '--staged', str(folder)], capture_output=True, text=True)
            print('SWARMHUB_UPDATER_RESULT:\(prefix)' + json.dumps({'exit_code': result.returncode, 'output': result.stdout}))
            if result.returncode != 0:
                raise SystemExit(result.returncode)
            print('SWARMHUB_TRANSFER_OK:\(prefix)')
        except Exception as error:
            print('SWARMHUB_TRANSFER_FAILED:\(prefix)' + json.dumps(str(error)))
            raise
        finally:
            shutil.rmtree(folder)
        SWARMHUB_STAGE
        """
    }

    static func instructions(_ transfer: StagedTransfer, profile: String, devModes: [String: Bool] = [:]) throws -> String {
        """
        Install the signed SwarmHub bytes already stored by the app in temporary Hermes sessions.
        Run exactly the first terminal command, then run the status command as a separate terminal call.
        Never extract or execute an archive yourself. Do not run apply without --staged: code waits for a separate confirmation.
        Do not modify Hermes, enable plugins or restart anything. A reply cannot establish install success.
        ````sh
        \(try command(transfer, profile: profile, devModes: devModes))
        ````
        Then, in a separate terminal call, run exactly:
        ```sh
        \(statusCommand)
        ```
        Reply briefly with the status, including pending_confirm or reload_pending. Do not emit skills_installed.
        """
    }
}

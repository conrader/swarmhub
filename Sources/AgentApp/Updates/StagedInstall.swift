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
        let floor = Floor(keys: max(box.checkpoint.keys, saved.keys), index: max(box.checkpoint.index, saved.index),
                          bundle: max(box.checkpoint.bundle, saved.bundle), manifest: saved.manifest)
        // Re-rendering a profile may resend the same bundle. Only the exact previously verified manifest may
        // reuse that floor, never another signed manifest at the same version.
        let repeatable = floor.bundle == saved.bundle && saved.manifest != nil
        let verificationFloor = UpdateFloors(keysVersion: floor.keys, indexSequence: floor.index,
                                             bundleVersion: repeatable ? max(0, floor.bundle - 1) : floor.bundle)
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

    /// This script travels as text; only the destination shell runs it. Archives remain base64 opaque bytes until
    /// the protected updater verifies them. mkdtemp prevents an earlier turn from planting staging symlinks.
    static func command(_ package: Package) throws -> String {
        let payload = try JSONEncoder().encode(package.files.mapValues { $0.base64EncodedString() }).base64EncodedString()
        let profiles = try JSONEncoder().encode(package.profiles).base64EncodedString()
        return """
        python3 -I -B <<'SWARMHUB_STAGE'
        import base64, json, os, pathlib, shutil, subprocess, tempfile
        state = pathlib.Path(os.environ.get('XDG_STATE_HOME', str(pathlib.Path.home() / '.local/state'))) / 'swarmhub-update'
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        folder = pathlib.Path(tempfile.mkdtemp(prefix='mac-stage-', dir=state))
        try:
            files = json.loads(base64.b64decode('\(payload)'))
            for name, encoded in files.items():
                target = folder / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(base64.b64decode(encoded, validate=True))
            prior = state / 'profiles.json'
            doc = json.loads(prior.read_bytes()) if prior.exists() else {'schema': 'swarmhub/profiles/1', 'profiles': []}
            rows = {row['name']: row for row in doc['profiles']}
            for row in json.loads(base64.b64decode('\(profiles)')):
                old = rows.get(row['name'])
                if old is not None:
                    row['skills'] = None if old.get('skills') is None else sorted(set(old['skills']) | set(row['skills']))
                rows[row['name']] = row
            doc['profiles'] = list(rows.values())
            (folder / 'profiles.json').write_text(json.dumps(doc))
            subprocess.run(['\(updater)', '--max-wait', '0', 'apply', '--staged', str(folder)], check=False)
        finally:
            shutil.rmtree(folder)
        SWARMHUB_STAGE
        """
    }

    static func instructions(_ package: Package) throws -> String {
        """
        Install these signed SwarmHub bytes for the requested profiles using the operator-installed updater.
        Run exactly the first terminal command, then run the status command as a separate terminal call.
        Never extract or execute an archive yourself. Do not run apply without --staged: code waits for a separate confirmation.
        Do not modify Hermes, enable plugins or restart anything. A reply cannot establish install success.
        ````sh
        \(try command(package))
        ````
        Then, in a separate terminal call, run exactly:
        ```sh
        \(statusCommand)
        ```
        Reply briefly with the status, including pending_confirm or reload_pending. Do not emit skills_installed.
        """
    }
}

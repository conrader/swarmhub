import CryptoKit
import Foundation

/// The signed baseline bundle embedded in the app build (CORE-PHASES.md P2c; CORE-PLAN.md §3.1 "fail closed"): the update
/// service's layout (`pins.json`, `keys.json`, `channels/<channel>.json`, `bundles/<N>.json`, `blobs/sha256/<sha256>`) in the
/// app's `Baseline` resource folder, written by `scripts/release/baseline.py embed`. A fresh app reads it from disk and
/// needs no network: it is the content the app ships, not a download.
///
/// This reader checks structure and hashes only: the bundle manifest's SHA-256 against the highest index line, and every
/// blob's size and SHA-256 against the manifest (an iOS build embeds only the blobs of components that target `ios`, so
/// iOS loads with `target: "ios"`). The build verified signatures (`check_baseline.py`); the app's code signature seals
/// these files. AppContent only loads this reader from the app bundle, never from a fetched store. Downloaded content
/// needs a runtime signature verifier (P0c/P4a). The floors and pins feed the update client (P4a).
public struct EmbeddedBaseline: Sendable, Equatable {
    public struct Component: Sendable, Equatable {
        public let kind: String
        public let contentClass: String
        public let name: String
        public let version: String
        public let targets: [String]
        public let sha256: String
        public let size: Int
    }

    public enum LoadError: Error, Equatable {
        case missing(String)
        case malformed(String)
        case manifestHashMismatch
        case blobMismatch(String)
    }

    public let directory: URL
    /// The raw pin file (`swarmhub/pins/1`) the baseline was signed under.
    public let pins: Data
    public let keysVersion: Int
    public let channel: String
    public let indexSequence: Int
    public let bundleVersion: Int
    public let label: String
    public let components: [Component]

    /// The baseline in `directory`, or a `LoadError`. Reads files only. With a `target`, only the blobs of components that
    /// target it must be present.
    public static func load(from directory: URL, channel: String = "stable", target: String? = nil) throws -> EmbeddedBaseline {
        let pins = try read(directory, "pins.json")
        let keys = try signed(read(directory, "keys.json"), "keys.json")
        let index = try signed(read(directory, "channels/\(channel).json"), "channels/\(channel).json")
        guard let keysVersion = keys["version"] as? Int, let sequence = index["seq"] as? Int,
              let lines = index["lines"] as? [[String: Any]] else { throw LoadError.malformed("keys.json or index") }
        let versions = lines.compactMap { line -> (Int, String)? in
            guard let version = line["bundle_version"] as? Int, let digest = line["manifest_sha256"] as? String else { return nil }
            return (version, digest)
        }
        guard versions.count == lines.count, let line = versions.max(by: { $0.0 < $1.0 }) else { throw LoadError.malformed("index lines") }
        let raw = try read(directory, "bundles/\(line.0).json")
        guard hex(raw) == line.1 else { throw LoadError.manifestHashMismatch }
        let manifest = try signed(raw, "bundles/\(line.0).json")
        guard manifest["version"] as? Int == line.0, let label = manifest["label"] as? String,
              let entries = manifest["components"] as? [[String: Any]] else { throw LoadError.malformed("bundle manifest") }
        let components = try entries.map(component)
        for item in components where target.map({ item.targets.contains($0) }) ?? true {
            let blob = try read(directory, "blobs/sha256/\(item.sha256)")
            guard blob.count == item.size, hex(blob) == item.sha256 else { throw LoadError.blobMismatch(item.name) }
        }
        return EmbeddedBaseline(directory: directory, pins: pins, keysVersion: keysVersion, channel: channel, indexSequence: sequence,
                                bundleVersion: line.0, label: label, components: components)
    }

    /// The first candidate folder that loads; nil when the build embeds no baseline.
    public static func locate(_ candidates: [URL], channel: String = "stable", target: String? = nil) -> EmbeddedBaseline? {
        for candidate in candidates {
            if let baseline = try? load(from: candidate, channel: channel, target: target) { return baseline }
        }
        return nil
    }

    /// The archive bytes of one component, re-checked against the manifest.
    public func blob(for item: Component) throws -> Data {
        let data = try Self.read(directory, "blobs/sha256/\(item.sha256)")
        guard data.count == item.size, Self.hex(data) == item.sha256 else { throw LoadError.blobMismatch(item.name) }
        return data
    }

    /// The components a platform consumes (`box`, `mac`, `ios`).
    public func components(for target: String) -> [Component] { components.filter { $0.targets.contains(target) } }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func read(_ directory: URL, _ path: String) throws -> Data {
        do { return try AppBundleResources.read(path, in: directory) } catch { throw LoadError.missing(path) }
    }

    private static func signed(_ data: Data, _ path: String) throws -> [String: Any] {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = envelope["signed"] as? [String: Any], envelope["signatures"] is [Any] else { throw LoadError.malformed(path) }
        return body
    }

    private static func component(_ entry: [String: Any]) throws -> Component {
        guard let kind = entry["kind"] as? String, let contentClass = entry["class"] as? String,
              let name = entry["name"] as? String, let version = entry["version"] as? String,
              let targets = entry["targets"] as? [String], let sha256 = entry["sha256"] as? String, let size = entry["size"] as? Int,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw LoadError.malformed("component") }
        return Component(kind: kind, contentClass: contentClass, name: name, version: version, targets: targets, sha256: sha256, size: size)
    }
}
